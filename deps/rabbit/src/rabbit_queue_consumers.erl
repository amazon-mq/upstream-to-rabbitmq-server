%% This Source Code Form is subject to the terms of the Mozilla Public
%% License, v. 2.0. If a copy of the MPL was not distributed with this
%% file, You can obtain one at https://mozilla.org/MPL/2.0/.
%%
%% Copyright (c) 2007-2026 Broadcom. All Rights Reserved. The term “Broadcom” refers to Broadcom Inc. and/or its subsidiaries. All rights reserved.
%%

-module(rabbit_queue_consumers).

-export([new/0, max_active_priority/1, inactive/1, all/1, all/3, count/0,
         unacknowledged_message_count/0, add/10, remove/4, erase_ch/2,
         deliver/5, record_ack/4, subtract_acks/3,
         possibly_unblock/3,
         resume_fun/0, notify_sent_fun/1, activate_limit_fun/0,
         drained/3, process_credit/5, get_link_state/2,
         utilisation/1, capacity/1, is_same/3, get_consumer/1, get/3,
         consumer_tag/1, get_infos/1, parse_prefetch_count/1,
         expire_acks/2, take_next_deadline/1, holds_acks/2]).

-export([deactivate_limit_fun/0]).

%%----------------------------------------------------------------------------

-define(QUEUE, lqueue).

-define(KEY_UNSENT_MESSAGE_LIMIT, classic_queue_consumer_unsent_message_limit).
-define(DEFAULT_UNSENT_MESSAGE_LIMIT, 200).

%% Utilisation average calculations are all in μs.
-define(USE_AVG_HALF_LIFE, 1000000.0).

-record(state, {consumers,
                use,
                %% earliest consumer timeout deadline among deliveries made
                %% since the last take_next_deadline/1
                next_deadline = infinity}).

-record(consumer, {tag, ack_required, prefetch, args, user, timeout}).

%% AMQP 1.0 link flow control state, see §2.6.7
-record(link_state, {delivery_count :: rabbit_queue_type:delivery_count(),
                     credit :: rabbit_queue_type:credit()}).

%% These are held in our process dictionary
%% channel record
-record(cr, {ch_pid,
             monitor_ref,
             acktags :: ?QUEUE:?QUEUE({ack(), rabbit_types:ctag() | none,
                                       deadline()}),
             consumer_count :: non_neg_integer(),
             %% Queue of {ChPid, #consumer{}} for consumers which have
             %% been blocked (rate/prefetch limited) for any reason
             blocked_consumers,
             %% The limiter itself
             limiter,
             %% Internal flow control for queue -> writer
             unsent_message_count :: non_neg_integer(),
             link_states :: #{rabbit_types:ctag() => #link_state{}},
             %% Ack tags requeued on consumer timeout, awaiting settlement
             timed_out_acks :: #{rabbit_types:ctag() | none => [ack()]},
             %% Consumers withheld from deliveries until the client settles
             %% all of their timed-out ack tags
             timed_out_consumers :: #{rabbit_types:ctag() => consumer()}
            }).

%%----------------------------------------------------------------------------

-type time_micros() :: non_neg_integer().
%% Absolute deadline in milliseconds, on the erlang:monotonic_time/1 scale.
-type deadline() :: integer().
-type ratio() :: float().
-type state() :: #state{consumers ::priority_queue:q(),
                        use       :: {'inactive',
                                      time_micros(), time_micros(), ratio()} |
                                     {'active', time_micros(), ratio()},
                        next_deadline :: deadline() | 'infinity'}.
-type consumer() :: #consumer{tag::rabbit_types:ctag(), ack_required::boolean(),
                              prefetch::non_neg_integer(), args::rabbit_framing:amqp_table(),
                              user::rabbit_types:username(),
                              timeout::non_neg_integer()}.
-type ch() :: pid().
-type ack() :: non_neg_integer().
-type cr_fun() :: fun ((#cr{}) -> #cr{}).
-type fetch_result() :: {rabbit_types:basic_message(), boolean(), ack()}.

%%----------------------------------------------------------------------------

-spec new() -> state().

new() ->
    Val = application:get_env(rabbit,
                              ?KEY_UNSENT_MESSAGE_LIMIT,
                              ?DEFAULT_UNSENT_MESSAGE_LIMIT),
    persistent_term:put(?KEY_UNSENT_MESSAGE_LIMIT, Val),
    #state{consumers = priority_queue:new(),
           use = {active,
                  erlang:monotonic_time(microsecond),
                  1.0}}.

-spec max_active_priority(state()) -> integer() | 'infinity' | 'empty'.

max_active_priority(#state{consumers = Consumers}) ->
    priority_queue:highest(Consumers).

-spec inactive(state()) -> boolean().

inactive(#state{consumers = Consumers}) ->
    priority_queue:is_empty(Consumers).

-spec all(state()) -> [{ch(), rabbit_types:ctag(), boolean(),
                        non_neg_integer(), boolean(), atom(),
                        rabbit_framing:amqp_table(), rabbit_types:username()}].

all(State) ->
    all(State, none, false).

all(#state{consumers = Consumers}, SingleActiveConsumer, SingleActiveConsumerOn) ->
    lists:foldl(fun (C, Acc0) ->
                        Acc = consumers(C#cr.blocked_consumers, SingleActiveConsumer, SingleActiveConsumerOn, Acc0),
                        timed_out_consumers(C, Acc)
                end,
                consumers(Consumers, SingleActiveConsumer, SingleActiveConsumerOn, []), all_ch_record()).

timed_out_consumers(#cr{ch_pid = ChPid, timed_out_consumers = TimedOut}, Acc) ->
    maps:fold(fun (CTag, #consumer{ack_required = Ack, prefetch = Prefetch,
                                   args = Args, user = Username}, Acc1) ->
                      [{ChPid, CTag, Ack, Prefetch, false, timed_out, Args, Username} | Acc1]
              end, Acc, TimedOut).

consumers(Consumers, SingleActiveConsumer, SingleActiveConsumerOn, Acc) ->
    ActiveActivityStatusFun = case SingleActiveConsumerOn of
                                  true ->
                                      fun({ChPid, Consumer}) ->
                                          case SingleActiveConsumer of
                                              {ChPid, Consumer} ->
                                                  {true, single_active};
                                              _ ->
                                                  {false, waiting}
                                          end
                                      end;
                                  false ->
                                      %% C = {ChPid, Consumer}
                                      fun(C) ->
                                          case is_blocked(C) of
                                              true  -> {true, blocked};
                                              false -> {true, up}
                                          end
                                      end
                              end,
    priority_queue:fold(
      fun ({ChPid, Consumer}, _P, Acc1) ->
              #consumer{tag = CTag, ack_required = Ack, prefetch = Prefetch,
                        args = Args, user = Username} = Consumer,
              {Active, ActivityStatus} = ActiveActivityStatusFun({ChPid, Consumer}),
              [{ChPid, CTag, Ack, Prefetch, Active, ActivityStatus, Args, Username} | Acc1]
      end, Acc, Consumers).

-spec count() -> non_neg_integer().

count() -> lists:sum([Count || #cr{consumer_count = Count} <- all_ch_record()]).

-spec unacknowledged_message_count() -> non_neg_integer().

unacknowledged_message_count() ->
    lists:sum([?QUEUE:len(C#cr.acktags) || C <- all_ch_record()]).

-spec add(ch(), rabbit_types:ctag(), boolean(), pid() | none, boolean(),
          {simple_prefetch, non_neg_integer()} | {credited, rabbit_queue_type:delivery_count()},
          rabbit_framing:amqp_table(),
          rabbit_types:username(), non_neg_integer(), state()) ->
    state().

add(ChPid, CTag, NoAck, LimiterPid, LimiterActive, Mode, Args, Username,
    Timeout,
    #state{consumers = Consumers,
           use = CUInfo} = State) ->
    C0 = #cr{consumer_count = Count,
             limiter        = Limiter,
             link_states = LinkStates} = ch_record(ChPid, LimiterPid),
    Limiter1 = case LimiterActive of
                   true  -> rabbit_limiter:activate(Limiter);
                   false -> Limiter
               end,
    C1 = C0#cr{consumer_count = Count + 1,
               limiter = Limiter1},
    C = case parse_credit_mode(Mode) of
            {0, auto} ->
                C1;
            {Credit, auto = Mode1} ->
                case NoAck of
                    true ->
                        C1;
                    false ->
                        Limiter2 = rabbit_limiter:credit(Limiter1, CTag, Credit, Mode1),
                        C1#cr{limiter = Limiter2}
                end;
            {InitialDeliveryCount, manual} ->
                C1#cr{link_states = LinkStates#{CTag => #link_state{
                                                           credit = 0,
                                                           delivery_count = InitialDeliveryCount}}}
        end,
    update_ch_record(C),
    Consumer = #consumer{tag          = CTag,
                         ack_required = not NoAck,
                         prefetch     = parse_prefetch_count(Mode),
                         args         = Args,
                         user         = Username,
                         timeout      = Timeout},
    State#state{consumers = add_consumer({ChPid, Consumer}, Consumers),
                use       = update_use(CUInfo, active)}.

-spec remove(ch(), rabbit_types:ctag(), rabbit_queue_type:cancel_reason(), state()) ->
    not_found | {[ack()], state()}.
remove(ChPid, CTag, Reason, State = #state{consumers = Consumers}) ->
    case lookup_ch(ChPid) of
        not_found ->
            not_found;
        C = #cr{acktags = AckTags0,
                consumer_count = Count,
                limiter = Limiter,
                blocked_consumers = Blocked,
                link_states = LinkStates,
                timed_out_acks = TimedOutAcks,
                timed_out_consumers = TimedOutConsumers} ->
            {Acks, AckTags} = case Reason of
                                  remove ->
                                      AckTags1 = ?QUEUE:to_list(AckTags0),
                                      {AckTags2, AckTags3} = lists:partition(
                                                               fun({_, Tag, _}) ->
                                                                       Tag =:= CTag
                                                               end, AckTags1),
                                      {lists:map(fun({Ack, _, _}) -> Ack end, AckTags2),
                                       ?QUEUE:from_list(AckTags3)};
                                  _ ->
                                      {[], AckTags0}
                              end,
            Limiter1 = case Count of
                           1 -> rabbit_limiter:deactivate(Limiter);
                           _ -> Limiter
                       end,
            Limiter2 = rabbit_limiter:forget_consumer(Limiter1, CTag),
            update_ch_record(C#cr{acktags = AckTags,
                                  consumer_count = Count - 1,
                                  limiter = Limiter2,
                                  blocked_consumers = remove_consumer(ChPid, CTag, Blocked),
                                  link_states = maps:remove(CTag, LinkStates),
                                  timed_out_acks = maps:remove(CTag, TimedOutAcks),
                                  timed_out_consumers = maps:remove(CTag, TimedOutConsumers)}),
            {Acks, State#state{consumers = remove_consumer(ChPid, CTag, Consumers)}}
    end.

-spec erase_ch(ch(), state()) ->
                      'not_found' | {[ack()], [rabbit_types:ctag()],
                                     state()}.

erase_ch(ChPid, State = #state{consumers = Consumers}) ->
    case lookup_ch(ChPid) of
        not_found ->
            not_found;
        C = #cr{ch_pid              = ChPid,
                acktags             = ChAckTags,
                blocked_consumers   = BlockedQ,
                timed_out_consumers = TimedOutConsumers} ->
            All = priority_queue:join(Consumers, BlockedQ),
            ok = erase_ch_record(C),
            Filtered = priority_queue:filter(chan_pred(ChPid, true), All),
            %% timed-out ack tags were requeued already and are not returned
            {[AckTag || {AckTag, _CTag, _Deadline} <- ?QUEUE:to_list(ChAckTags)],
             tags(priority_queue:to_list(Filtered)) ++ maps:keys(TimedOutConsumers),
             State#state{consumers = remove_consumers(ChPid, Consumers)}}
    end.

-spec deliver(fun ((boolean()) -> {fetch_result(), T}),
              rabbit_amqqueue:name(), state(), boolean(),
              none | {ch(), rabbit_types:ctag()} | {ch(), consumer()}) ->
                     {'delivered',   [{ch(), consumer()}], T, state()} |
                     {'undelivered', [{ch(), consumer()}], state()}.

deliver(FetchFun, QName, State, SingleActiveConsumerIsOn, ActiveConsumer) ->
    deliver(FetchFun, QName, [], State, SingleActiveConsumerIsOn, ActiveConsumer).

deliver(_FetchFun, _QName, Blocked, State, true, none) ->
    {undelivered, Blocked,
        State#state{use = update_use(State#state.use, inactive)}};
deliver(FetchFun, QName, Blocked, State = #state{consumers = Consumers}, true,
        SingleActiveConsumer) ->
    {ChPid, Consumer} = SingleActiveConsumer,
    %% blocked (rate/prefetch limited) consumers are removed from the queue state,
    %% but not the exclusive_consumer field, so we need to do this check to
    %% avoid adding the exclusive consumer to the channel record
    %% over and over
    case is_blocked(SingleActiveConsumer) orelse
         is_timed_out(SingleActiveConsumer) of
        true ->
            {undelivered, Blocked,
                State#state{use = update_use(State#state.use, inactive)}};
        false ->
            case deliver_to_consumer(FetchFun, SingleActiveConsumer, QName) of
                {delivered, Deadline, R} ->
                    {delivered, Blocked, R, update_next_deadline(Deadline, State)};
                {undelivered, E} ->
                    Consumers1 = remove_consumer(ChPid, Consumer#consumer.tag, Consumers),
                    {undelivered, [E | Blocked],
                        State#state{consumers = Consumers1, use = update_use(State#state.use, inactive)}}
            end
    end;
deliver(FetchFun, QName, Blocked,
    State = #state{consumers = Consumers}, false, _SingleActiveConsumer) ->
    case priority_queue:out_p(Consumers) of
        {empty, _} ->
            {undelivered, Blocked,
             State#state{use = update_use(State#state.use, inactive)}};
        {{value, QEntry, Priority}, Tail} ->
            case deliver_to_consumer(FetchFun, QEntry, QName) of
                {delivered, Deadline, R} ->
                    {delivered, Blocked, R,
                     update_next_deadline(
                       Deadline,
                       State#state{consumers = priority_queue:in(QEntry, Priority,
                                                                 Tail)})};
                {undelivered, E} ->
                    deliver(FetchFun, QName, [E | Blocked],
                            State#state{consumers = Tail}, false, _SingleActiveConsumer)
            end
    end.

deliver_to_consumer(FetchFun,
                    E = {ChPid, Consumer = #consumer{tag = CTag}},
                    QName) ->
    C = #cr{link_states = LinkStates} = lookup_ch(ChPid),
    case LinkStates of
        #{CTag := #link_state{delivery_count = DelCount,
                              credit = Credit} = LinkState0} ->
            %% bypass credit flow for link credit consumers
            %% as it is handled separately
            case Credit > 0 of
                true ->
                    LinkState = LinkState0#link_state{
                                  delivery_count = serial_number:add(DelCount, 1),
                                  credit = Credit - 1},
                    C1 = C#cr{link_states = maps:update(CTag, LinkState, LinkStates)},
                    {Deadline, R} = deliver_to_consumer(FetchFun, Consumer, C1, QName),
                    {delivered, Deadline, R};
                false ->
                    block_consumer(C, E),
                    {undelivered, E}
            end;
        _ ->
            %% not a link credit consumer, use credit flow
            case is_ch_blocked(C) of
                true ->
                    block_consumer(C, E),
                    {undelivered, E};
                false ->
                    case rabbit_limiter:can_send(C#cr.limiter,
                                                 Consumer#consumer.ack_required,
                                                 CTag) of
                        {suspend, Limiter} ->
                            block_consumer(C#cr{limiter = Limiter}, E),
                            {undelivered, E};
                        {continue, Limiter} ->
                            {Deadline, R} = deliver_to_consumer(
                                              FetchFun, Consumer,
                                              C#cr{limiter = Limiter}, QName),
                            {delivered, Deadline, R}
                    end
            end
    end.

deliver_to_consumer(FetchFun,
                    #consumer{tag          = CTag,
                              ack_required = AckRequired,
                              timeout      = Timeout},
                    C = #cr{ch_pid               = ChPid,
                            acktags              = ChAckTags,
                            unsent_message_count = Count},
                    QName) ->
    {{Message, IsDelivered, AckTag}, R} = FetchFun(AckRequired),
    Msg= {QName, self(), AckTag, IsDelivered, Message},
    rabbit_classic_queue:deliver_to_consumer(ChPid, QName, CTag, AckRequired,
                                              Msg),
    {ChAckTags1, Deadline} =
        case AckRequired of
            true  -> D = erlang:monotonic_time(millisecond) + Timeout,
                     {?QUEUE:in({AckTag, CTag, D}, ChAckTags), D};
            false -> {ChAckTags, infinity}
        end,
    update_ch_record(C#cr{acktags              = ChAckTags1,
                          unsent_message_count = Count + 1}),
    {Deadline, R}.

update_next_deadline(Deadline, State = #state{next_deadline = Next}) ->
    State#state{next_deadline = min(Deadline, Next)}.

-spec take_next_deadline(state()) -> {deadline() | 'infinity', state()}.

take_next_deadline(#state{next_deadline = infinity} = State) ->
    {infinity, State};
take_next_deadline(#state{next_deadline = Deadline} = State) ->
    {Deadline, State#state{next_deadline = infinity}}.

is_blocked(Consumer = {ChPid, _C}) ->
    case lookup_ch(ChPid) of
        not_found ->
            false;
        #cr{blocked_consumers = BlockedConsumers} ->
            priority_queue:member(Consumer, BlockedConsumers)
    end.

is_timed_out({ChPid, #consumer{tag = CTag}}) ->
    case lookup_ch(ChPid) of
        not_found ->
            false;
        #cr{timed_out_consumers = TimedOutConsumers} ->
            is_map_key(CTag, TimedOutConsumers)
    end.

-spec record_ack(ch(), pid(), ack(), deadline()) -> 'ok'.

record_ack(ChPid, LimiterPid, AckTag, Deadline) ->
    C = #cr{acktags = ChAckTags} = ch_record(ChPid, LimiterPid),
    update_ch_record(
      C#cr{acktags = ?QUEUE:in({AckTag, none, Deadline}, ChAckTags)}),
    ok.

%% Returns the ack tags that are still known to the queue; the settlement
%% of ack tags that timed out is recorded but they are not returned since
%% their messages were requeued when the consumer timeout fired.
-spec subtract_acks(ch(), [ack()], state()) ->
                           'not_found' |
                           {[ack()], [{ch(), consumer()}], state()}.

subtract_acks(ChPid, AckTags, State) ->
    case lookup_ch(ChPid) of
        not_found ->
            not_found;
        C = #cr{acktags = ChAckTags, limiter = Lim} ->
            {Matched, CTagCounts0, Unmatched, AckTags2} =
                subtract_acks(AckTags, ChAckTags),
            {CTagCounts, Resumed, C1} =
                settle_timed_out(Unmatched, CTagCounts0,
                                 C#cr{acktags = AckTags2}),
            {Unblocked, Lim2} =
                maps:fold(
                  fun (CTag, Count, {UnblockedN, LimN}) ->
                          {Unblocked1, LimN1} =
                              rabbit_limiter:ack_from_queue(LimN, CTag, Count),
                          {UnblockedN orelse Unblocked1, LimN1}
                  end, {false, Lim}, CTagCounts),
            C2 = C1#cr{limiter = Lim2},
            State1 = lists:foldl(fun (Entry, S = #state{consumers = Cons}) ->
                                         S#state{consumers = add_consumer(Entry, Cons),
                                                 use = update_use(S#state.use, active)}
                                 end, State, Resumed),
            case Unblocked of
                true  -> case unblock(C2, State1) of
                             unchanged ->
                                 {Matched, Resumed, State1};
                             {unblocked, UnblockedConsumers, State2} ->
                                 {Matched, Resumed ++ UnblockedConsumers, State2}
                         end;
                false -> update_ch_record(C2),
                         {Matched, Resumed, State1}
            end
    end.

subtract_acks(AckTags, AckQ) ->
    subtract_acks0(maps:from_keys(AckTags, true), [], [], maps:new(), AckQ).

subtract_acks0(Pending, Prefix, Matched, CTagCounts, AckQ)
  when map_size(Pending) =:= 0 ->
    {lists:reverse(Matched), CTagCounts, [],
     ?QUEUE:join(?QUEUE:from_list(lists:reverse(Prefix)), AckQ)};
subtract_acks0(Pending, Prefix, Matched, CTagCounts, AckQ) ->
    case ?QUEUE:out(AckQ) of
        {{value, {T, CTag, _Deadline} = V}, QTail} ->
            case maps:take(T, Pending) of
                {_, Pending1} ->
                    subtract_acks0(Pending1, Prefix, [T | Matched],
                                   maps:update_with(CTag, fun (Old) -> Old + 1 end, 1, CTagCounts),
                                   QTail);
                error ->
                    subtract_acks0(Pending, [V | Prefix], Matched, CTagCounts, QTail)
            end;
        {empty, _} ->
            {lists:reverse(Matched), CTagCounts, maps:keys(Pending),
             ?QUEUE:from_list(lists:reverse(Prefix))}
    end.

settle_timed_out([], CTagCounts, C) ->
    {CTagCounts, [], C};
settle_timed_out(AckTags, CTagCounts0,
                 C = #cr{ch_pid = ChPid,
                         timed_out_acks = TimedOutAcks0,
                         timed_out_consumers = TimedOutConsumers0}) ->
    {CTagCounts, TimedOutAcks, Drained} =
        lists:foldl(
          fun (AckTag, {Counts, TOA, DrainedAcc}) ->
                  case take_timed_out_ack(AckTag, maps:iterator(TOA)) of
                      error ->
                          {Counts, TOA, DrainedAcc};
                      {CTag, []} ->
                          {maps:update_with(CTag, fun (Old) -> Old + 1 end, 1, Counts),
                           maps:remove(CTag, TOA), [CTag | DrainedAcc]};
                      {CTag, Rem} ->
                          {maps:update_with(CTag, fun (Old) -> Old + 1 end, 1, Counts),
                           maps:update(CTag, Rem, TOA), DrainedAcc}
                  end
          end, {CTagCounts0, TimedOutAcks0, []}, AckTags),
    {Resumed, TimedOutConsumers} =
        lists:foldl(
          fun (CTag, {Rs, TOC}) ->
                  case maps:take(CTag, TOC) of
                      {Consumer, TOC1} -> {[{ChPid, Consumer} | Rs], TOC1};
                      error            -> {Rs, TOC}
                  end
          end, {[], TimedOutConsumers0}, Drained),
    {CTagCounts, Resumed,
     C#cr{timed_out_acks = TimedOutAcks,
          timed_out_consumers = TimedOutConsumers}}.

take_timed_out_ack(AckTag, Iter) ->
    case maps:next(Iter) of
        none ->
            error;
        {CTag, AckTags, Iter1} ->
            case lists:member(AckTag, AckTags) of
                true  -> {CTag, lists:delete(AckTag, AckTags)};
                false -> take_timed_out_ack(AckTag, Iter1)
            end
    end.

%% Removes all ack tags whose deadline has passed, withholding the affected
%% consumers from further deliveries until the client settles those tags.
%% The caller is responsible for requeueing the expired ack tags.
-spec expire_acks(integer(), state()) ->
    {[{ch(), rabbit_types:ctag() | none, [ack()]}],
     deadline() | 'infinity', state()}.

expire_acks(Now, State) ->
    lists:foldl(fun (C, Acc) -> expire_ch_acks(Now, C, Acc) end,
                {[], infinity, State}, all_ch_record()).

expire_ch_acks(Now, C = #cr{ch_pid = ChPid,
                            acktags = ChAckTags,
                            timed_out_acks = TimedOutAcks},
               {Expired0, NextDeadline0, State0}) ->
    {KeptRev, ExpiredByCTag, NextDeadline} =
        lists:foldl(
          fun ({_AckTag, _CTag, Deadline} = E, {Kept, Exp, Next})
                when Deadline > Now ->
                  {[E | Kept], Exp, min(Deadline, Next)};
              ({AckTag, CTag, _Deadline}, {Kept, Exp, Next}) ->
                  {Kept,
                   maps:update_with(CTag, fun (Acks) -> [AckTag | Acks] end,
                                    [AckTag], Exp),
                   Next}
          end, {[], #{}, NextDeadline0}, ?QUEUE:to_list(ChAckTags)),
    case map_size(ExpiredByCTag) of
        0 ->
            {Expired0, NextDeadline, State0};
        _ ->
            C1 = C#cr{acktags = ?QUEUE:from_list(lists:reverse(KeptRev)),
                      timed_out_acks =
                          maps:merge_with(fun (_, Old, New) -> New ++ Old end,
                                          TimedOutAcks, ExpiredByCTag)},
            {C2, State} = park_consumers(maps:keys(ExpiredByCTag), C1, State0),
            update_ch_record(C2),
            Expired = maps:fold(fun (CTag, Acks, Acc) ->
                                        [{ChPid, CTag, lists:sort(Acks)} | Acc]
                                end, Expired0, ExpiredByCTag),
            {Expired, NextDeadline, State}
    end.

park_consumers(CTags, C, State) ->
    lists:foldl(fun (none, Acc)  -> Acc;
                    (CTag, {CN, StateN}) -> park_consumer(CTag, CN, StateN)
                end, {C, State}, CTags).

park_consumer(CTag, C = #cr{ch_pid = ChPid,
                            blocked_consumers = Blocked,
                            timed_out_consumers = TimedOutConsumers},
              State = #state{consumers = Consumers}) ->
    case is_map_key(CTag, TimedOutConsumers) of
        true ->
            {C, State};
        false ->
            case get(ChPid, CTag, State) of
                {_ChPid, Consumer} ->
                    {C#cr{timed_out_consumers = TimedOutConsumers#{CTag => Consumer}},
                     State#state{consumers = remove_consumer(ChPid, CTag, Consumers)}};
                undefined ->
                    Pred = fun ({_P, {CP, #consumer{tag = CT}}}) ->
                                   CP =:= ChPid andalso CT =:= CTag
                           end,
                    case lists:search(Pred, priority_queue:to_list(Blocked)) of
                        {value, {_P, {_ChPid, Consumer}}} ->
                            {C#cr{blocked_consumers = remove_consumer(ChPid, CTag, Blocked),
                                  timed_out_consumers = TimedOutConsumers#{CTag => Consumer}},
                             State};
                        false ->
                            {C, State}
                    end
            end
    end.

-spec holds_acks(ch(), rabbit_types:ctag()) -> boolean().

holds_acks(ChPid, CTag) ->
    case lookup_ch(ChPid) of
        not_found ->
            false;
        #cr{acktags = ChAckTags} ->
            lists:any(fun ({_AckTag, CT, _Deadline}) -> CT =:= CTag end,
                      ?QUEUE:to_list(ChAckTags))
    end.

-spec possibly_unblock(cr_fun(), ch(), state()) ->
                              'unchanged' |
                              {'unblocked', [{ch(), consumer()}], state()}.

possibly_unblock(Update, ChPid, State) ->
    case lookup_ch(ChPid) of
        not_found -> unchanged;
        C         -> C1 = Update(C),
                     case is_ch_blocked(C) andalso not is_ch_blocked(C1) of
                         false -> update_ch_record(C1),
                                  unchanged;
                         true  -> unblock(C1, State)
                     end
    end.

unblock(C = #cr{blocked_consumers = BlockedQ,
                limiter = Limiter,
                link_states = LinkStates},
        State = #state{consumers = Consumers, use = Use}) ->
    case lists:partition(
           fun({_P, {_ChPid, #consumer{tag = CTag}}}) ->
                   case maps:find(CTag, LinkStates) of
                       {ok, #link_state{credit = Credits}}
                         when Credits > 0 ->
                           false;
                       {ok, _Exhausted} ->
                           true;
                       error ->
                           rabbit_limiter:is_consumer_blocked(Limiter, CTag)
                   end
           end, priority_queue:to_list(BlockedQ)) of
        {_, []} ->
            update_ch_record(C),
            unchanged;
        {Blocked, Unblocked} ->
            BlockedQ1  = priority_queue:from_list(Blocked),
            UnblockedQ = priority_queue:from_list(Unblocked),
            update_ch_record(C#cr{blocked_consumers = BlockedQ1}),
            UnblockedConsumers = [E || {_P, E} <- Unblocked],
            {unblocked, UnblockedConsumers,
             State#state{consumers = priority_queue:join(Consumers, UnblockedQ),
                         use       = update_use(Use, active)}}
    end.

-spec resume_fun()                       -> cr_fun().

resume_fun() ->
    fun (C = #cr{limiter = Limiter}) ->
            C#cr{limiter = rabbit_limiter:resume(Limiter)}
    end.

-spec notify_sent_fun(non_neg_integer()) -> cr_fun().

notify_sent_fun(Credit) ->
    fun (C = #cr{unsent_message_count = Count}) ->
            C#cr{unsent_message_count = Count - Credit}
    end.

-spec activate_limit_fun()               -> cr_fun().

activate_limit_fun() ->
    fun (C = #cr{limiter = Limiter}) ->
            C#cr{limiter = rabbit_limiter:activate(Limiter)}
    end.

-spec deactivate_limit_fun()               -> cr_fun().

deactivate_limit_fun() ->
    fun (C = #cr{limiter = Limiter}) ->
            C#cr{limiter = rabbit_limiter:deactivate(Limiter)}
    end.

-spec drained(rabbit_queue_type:delivery_count(), ch(), rabbit_types:ctag()) -> ok.
drained(AdvancedDeliveryCount, ChPid, CTag) ->
    case lookup_ch(ChPid) of
        C0 = #cr{link_states = LinkStates = #{CTag := LinkState0}} ->
            LinkState = LinkState0#link_state{delivery_count = AdvancedDeliveryCount,
                                              credit = 0},
            C = C0#cr{link_states = maps:update(CTag, LinkState, LinkStates)},
            update_ch_record(C);
        _ ->
            ok
    end.

-spec process_credit(rabbit_queue_type:delivery_count(),
                     rabbit_queue_type:credit(),
                     ch(),
                     rabbit_types:ctag(),
                     state()) ->
    'unchanged' | {'unblocked', [{ch(), consumer()}], state()}.
process_credit(DeliveryCountRcv, LinkCreditRcv, ChPid, CTag, State) ->
    case lookup_ch(ChPid) of
        #cr{link_states = LinkStates = #{CTag := LinkState =
                                         #link_state{delivery_count = DeliveryCountSnd,
                                                     credit = OldLinkCreditSnd}},
            unsent_message_count = _Count} = C0 ->
            LinkCreditSnd = amqp10_util:link_credit_snd(DeliveryCountRcv,
                                                        LinkCreditRcv,
                                                        DeliveryCountSnd),
            C = C0#cr{link_states = maps:update(CTag,
                                                LinkState#link_state{credit = LinkCreditSnd},
                                                LinkStates)},
            case OldLinkCreditSnd > 0 orelse
                 LinkCreditSnd < 1 of
                true ->
                    update_ch_record(C),
                    unchanged;
                false ->
                    unblock(C, State)
            end;
        _ ->
            unchanged
    end.

-spec get_link_state(pid(), rabbit_types:ctag()) ->
    {rabbit_queue_type:delivery_count(), rabbit_queue_type:credit()} | not_found.
get_link_state(ChPid, CTag) ->
    case lookup_ch(ChPid) of
        #cr{link_states = #{CTag := #link_state{delivery_count = DeliveryCount,
                                                credit = Credit}}} ->
            {DeliveryCount, Credit};
        _ ->
            not_found
    end.

-spec utilisation(state()) -> ratio().
utilisation(State) ->
    capacity(State).

-spec capacity(state()) -> ratio().
capacity(#state{use = {active, Since, Avg}}) ->
    use_avg(erlang:monotonic_time(micro_seconds) - Since, 0, Avg);
capacity(#state{use = {inactive, Since, Active, Avg}}) ->
    use_avg(Active, erlang:monotonic_time(micro_seconds) - Since, Avg).

is_same(ChPid, ConsumerTag, {ChPid, #consumer{tag = ConsumerTag}}) ->
    true;
is_same(_ChPid, _ConsumerTag, _Consumer) ->
    false.

get_consumer(#state{consumers = Consumers}) ->
    case priority_queue:out_p(Consumers) of
        {{value, Consumer, _Priority}, _Tail} -> Consumer;
        {empty, _} -> undefined
    end.

-spec get(ch(), rabbit_types:ctag(), state()) ->
    undefined | {ch(), consumer()}.

get(ChPid, ConsumerTag, #state{consumers = Consumers}) ->
    Consumers1 = priority_queue:filter(fun ({CP, #consumer{tag = CT}}) ->
                            (CP == ChPid) and (CT == ConsumerTag)
                          end, Consumers),
    case priority_queue:out_p(Consumers1) of
        {empty, _} -> undefined;
        {{value, Consumer, _Priority}, _Tail} -> Consumer
    end.

-spec get_infos(consumer()) -> term().

get_infos(Consumer) ->
    {Consumer#consumer.tag,Consumer#consumer.ack_required,
     Consumer#consumer.prefetch, Consumer#consumer.args}.

-spec consumer_tag(consumer()) -> rabbit_types:ctag().

consumer_tag(#consumer{tag = CTag}) ->
    CTag.



%%----------------------------------------------------------------------------

parse_prefetch_count({simple_prefetch, Prefetch}) ->
    Prefetch;
parse_prefetch_count({credited, _InitialDeliveryCount}) ->
    0.

-spec parse_credit_mode(rabbit_queue_type:consume_mode()) ->
    {Prefetch :: non_neg_integer(), auto | manual}.
parse_credit_mode({credited, InitialDeliveryCount}) ->
    {InitialDeliveryCount, manual};
parse_credit_mode({simple_prefetch, Prefetch}) ->
    {Prefetch, auto}.

lookup_ch(ChPid) ->
    case get({ch, ChPid}) of
        undefined -> not_found;
        C         -> C
    end.

ch_record(ChPid, LimiterPid) ->
    Key = {ch, ChPid},
    case get(Key) of
        undefined -> MonitorRef = erlang:monitor(process, ChPid),
                     Limiter = rabbit_limiter:client(LimiterPid),
                     C = #cr{ch_pid               = ChPid,
                             monitor_ref          = MonitorRef,
                             acktags              = ?QUEUE:new(),
                             consumer_count       = 0,
                             blocked_consumers    = priority_queue:new(),
                             limiter              = Limiter,
                             unsent_message_count = 0,
                             link_states          = #{},
                             timed_out_acks       = #{},
                             timed_out_consumers  = #{}},
                     put(Key, C),
                     C;
        C = #cr{} -> C
    end.

update_ch_record(C = #cr{consumer_count       = ConsumerCount,
                         acktags              = ChAckTags,
                         unsent_message_count = UnsentMessageCount,
                         timed_out_acks       = TimedOutAcks}) ->
    case {?QUEUE:is_empty(ChAckTags), ConsumerCount, UnsentMessageCount,
          map_size(TimedOutAcks)} of
        {true, 0, 0, 0} -> ok = erase_ch_record(C);
        _               -> ok = store_ch_record(C)
    end,
    ok.

store_ch_record(C = #cr{ch_pid = ChPid}) ->
    put({ch, ChPid}, C),
    ok.

erase_ch_record(#cr{ch_pid = ChPid, monitor_ref = MonitorRef}) ->
    erlang:demonitor(MonitorRef),
    erase({ch, ChPid}),
    ok.

all_ch_record() -> [C || {{ch, _}, C} <- get()].

block_consumer(C = #cr{blocked_consumers = Blocked}, QEntry) ->
    update_ch_record(C#cr{blocked_consumers = add_consumer(QEntry, Blocked)}).

is_ch_blocked(#cr{unsent_message_count = Count, limiter = Limiter}) ->
    UnsentMessageLimit = persistent_term:get(?KEY_UNSENT_MESSAGE_LIMIT),
    Count >= UnsentMessageLimit orelse rabbit_limiter:is_suspended(Limiter).

tags(CList) -> [CTag || {_P, {_ChPid, #consumer{tag = CTag}}} <- CList].

add_consumer(Key = {_ChPid, #consumer{args = Args}}, Queue) ->
    Priority = case rabbit_misc:table_lookup(Args, <<"x-priority">>) of
                   {_, P} -> P;
                   _      -> 0
               end,
    priority_queue:in(Key, Priority, Queue).

remove_consumer(ChPid, CTag, Queue) ->
    priority_queue:filter(fun ({CP, #consumer{tag = CT}}) ->
                                  (CP /= ChPid) or (CT /= CTag)
                          end, Queue).

remove_consumers(ChPid, Queue) ->
    priority_queue:filter(chan_pred(ChPid, false), Queue).

chan_pred(ChPid, Want) ->
    fun ({CP, _Consumer}) when CP =:= ChPid -> Want;
        (_)                                 -> not Want
    end.

update_use({inactive, _, _, _}   = CUInfo, inactive) ->
    CUInfo;
update_use({active,   _, _}      = CUInfo,   active) ->
    CUInfo;
update_use({active,   Since,         Avg}, inactive) ->
    Now = erlang:monotonic_time(micro_seconds),
    {inactive, Now, Now - Since, Avg};
update_use({inactive, Since, Active, Avg},   active) ->
    Now = erlang:monotonic_time(micro_seconds),
    {active, Now, use_avg(Active, Now - Since, Avg)}.

use_avg(0, 0, Avg) ->
    Avg;
use_avg(Active, Inactive, Avg) ->
    Time = Inactive + Active,
    rabbit_misc:moving_average(Time, ?USE_AVG_HALF_LIFE, Active / Time, Avg).
