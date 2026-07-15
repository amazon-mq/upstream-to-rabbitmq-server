%% This Source Code Form is subject to the terms of the Mozilla Public
%% License, v. 2.0. If a copy of the MPL was not distributed with this
%% file, You can obtain one at https://mozilla.org/MPL/2.0/.
%%
%% Copyright (c) 2007-2026 Broadcom. All Rights Reserved. The term “Broadcom” refers to Broadcom Inc. and/or its subsidiaries. All rights reserved.
%%

%% Stateful property test of rabbit_queue_consumers, with a focus on the
%% consumer timeout machinery: delivery deadlines, expiry, parking,
%% settlement of released (timed-out) ack tags, and ack tag reuse.
%%
%% The test process plays the roles of both the queue process and the
%% channel. Time is explicit: consumer timeouts come in tiers that are
%% either due immediately or far in the future, and expire_acks/2 is
%% called with a chosen "now", so no sleeping is involved and every
%% command's outcome is deterministic.
%%
%% Two properties of the real system are modelled adversarially:
%%
%% * The ack tag of a message is its backing queue sequence id, which is
%%   reused when a requeued message is delivered again. Here the ack tag
%%   of a message is always the message id itself, so every redelivery
%%   reuses the tag and a tag can be pending both as a live delivery and
%%   as a released one.
%%
%% * Consumers are assigned distinct x-priority values, which makes the
%%   delivery target deterministic (the highest-priority active consumer)
%%   and lets the model predict every outcome without ambiguity.
-module(queue_consumers_prop_SUITE).
-behaviour(proper_statem).

-compile(nowarn_export_all).
-compile(export_all).

-include_lib("proper/include/proper.hrl").
-include_lib("eunit/include/eunit.hrl").

-define(NUM_TESTS, 500).

-define(SUT, '$queue_consumers_prop_state').
-define(QNAME, rabbit_misc:r(<<"/">>, queue, <<"queue_consumers_prop">>)).

%% Message ids double as ack tags; a small pool maximises tag reuse.
-define(MSGS, [1, 2, 3, 4, 5, 6]).
-define(CTAGS, [<<"c1">>, <<"c2">>, <<"c3">>, <<"c4">>]).

%% Timeout tiers in milliseconds. A test run lasts far less than the
%% 'never' tier, and expiry offsets fall strictly between the tiers.
-define(TIMEOUT_DUE, 0).
-define(TIMEOUT_NEVER, 3_600_000_000).
-define(EXPIRE_DUE_OFFSET, 1_800_000).
-define(EXPIRE_ALL_OFFSET, 7_200_000_000).

%% Model state. Every message is in exactly one of ready, live (mapped
%% to its holder and the holder's timeout tier at delivery time) or
%% acked. Released ack tags are a separate ledger, mirroring the fact
%% that a released tag's message returns to the queue and may be
%% delivered again while its settlement is still owed.
-record(m, {
    consumers = #{} :: #{binary() => #{tier := due | never,
                                       parked := boolean()}},
    ready = ?MSGS :: [pos_integer()],
    live = #{} :: #{pos_integer() => {binary(), due | never}},
    released = #{} :: #{pos_integer() => binary()},
    acked = [] :: [pos_integer()]
}).

%% Common Test.

all() ->
    [queue_consumers,
     orphaned_debt].

init_per_suite(Config) ->
    Config.

end_per_suite(Config) ->
    Config.

queue_consumers(_Config) ->
    true = proper:quickcheck(prop_queue_consumers(),
                             [{on_output, on_output_fun()},
                              {numtests, ?NUM_TESTS}]).

on_output_fun() ->
    fun (".", _) -> ok;
        ("!", _) -> ok;
        ("~n", _) -> ok;
        (F, A) -> io:format(F, A)
    end.

%% A deterministic corner found while modelling: a consumer cancelled
%% with pending deliveries leaves orphaned released debts under its
%% consumer tag once those deliveries expire. A consumer that later
%% re-subscribes with the same tag must not resume while any debt under
%% the tag is unsettled.
orphaned_debt(_Config) ->
    cleanup(),
    put(?SUT, rabbit_queue_consumers:new()),
    try
        ok = cmd_add(<<"c1">>, due),
        {delivered, <<"c1">>, 1} = cmd_deliver(1),
        %% Cancelling keeps the pending delivery tracked.
        [] = cmd_cancel(<<"c1">>, cancel),
        %% The delivery expires; there is no consumer to park.
        ?assertEqual({[{1, <<"c1">>}], []}, cmd_expire(due)),
        %% The client re-subscribes with the same consumer tag; the new
        %% consumer inherits the tag's released debt.
        ok = cmd_add(<<"c1">>, due),
        {delivered, <<"c1">>, 2} = cmd_deliver(2),
        ?assertEqual({[{2, <<"c1">>}], []}, cmd_expire(due)),
        %% Settling the orphaned debt must not resume the consumer while
        %% the second released tag is still owed.
        ?assertEqual([], cmd_settle_released(1)),
        ?assertEqual([{<<"c1">>, timed_out}], cmd_listing()),
        ?assertEqual([<<"c1">>], cmd_settle_released(2)),
        ?assertEqual([{<<"c1">>, up}], cmd_listing())
    after
        cleanup()
    end,
    ok.

%% Property.

prop_queue_consumers() ->
    ?FORALL(Commands, commands(?MODULE),
        begin
            cleanup(),
            put(?SUT, rabbit_queue_consumers:new()),
            {History, State, Result} = run_commands(?MODULE, Commands),
            cleanup(),
            ?WHENFAIL(io:format("History: ~tp~nState: ~tp~nResult: ~tp~n",
                                [History, State, Result]),
                      aggregate(command_names(Commands), Result =:= ok))
        end).

%% rabbit_queue_consumers keeps per-channel records in the process
%% dictionary and delivers by sending to the channel pid, which is
%% this process. Both must be cleaned between runs.
cleanup() ->
    _ = [begin
             MRef = element(3, C),
             _ = is_reference(MRef) andalso erlang:demonitor(MRef, [flush]),
             erase(K)
         end || {{ch, _} = K, C} <- get()],
    _ = erase(?SUT),
    flush_deliveries().

flush_deliveries() ->
    receive
        {'$gen_cast', {queue_event, _, _}} -> flush_deliveries()
    after 0 ->
        ok
    end.

%% Generators.

initial_state() ->
    #m{}.

command(St) ->
    weighted_union(
      [{10, {call, ?MODULE, cmd_add, [free_ctag(St), oneof([due, never])]}}
       || can_add(St)] ++
      [{8, {call, ?MODULE, cmd_cancel,
            [consuming_ctag(St), oneof([cancel, remove])]}}
       || map_size(St#m.consumers) > 0] ++
      [{30, {call, ?MODULE, cmd_deliver, [ready_msg(St)]}}
       || St#m.ready =/= [], eligible(St) =/= []] ++
      %% Deliveries must not reach parked (or absent) consumers.
      [{5, {call, ?MODULE, cmd_deliver_none, [ready_msg(St)]}}
       || St#m.ready =/= [], eligible(St) =:= []] ++
      [{15, {call, ?MODULE, cmd_expire, [due]}},
       {5, {call, ?MODULE, cmd_expire, [all]}},
       {3, {call, ?MODULE, cmd_listing, []}}] ++
      [{15, {call, ?MODULE, cmd_ack_live, [live_tag(St)]}}
       || map_size(St#m.live) > 0] ++
      [{10, {call, ?MODULE, cmd_requeue_live, [live_tag(St)]}}
       || map_size(St#m.live) > 0] ++
      %% The partitioned settlement of a released tag, as performed by
      %% AMQP 0-9-1 channels via the 'released' settle operation.
      [{15, {call, ?MODULE, cmd_settle_released, [released_tag(St)]}}
       || map_size(St#m.released) > 0] ++
      %% The unpartitioned settlement of a released tag, as performed by
      %% AMQP 1.0 sessions requeueing a released delivery: live entries
      %% win, the released ledger is only drained on a live miss.
      [{10, {call, ?MODULE, cmd_settle_stale, [released_tag(St)]}}
       || map_size(St#m.released) > 0] ++
      [{2, {call, ?MODULE, cmd_erase_ch, []}}
       || map_size(St#m.consumers) > 0]).

free_ctag(#m{consumers = Cs}) ->
    elements([C || C <- ?CTAGS, not is_map_key(C, Cs)]).

consuming_ctag(#m{consumers = Cs}) ->
    elements(maps:keys(Cs)).

ready_msg(#m{ready = Ready}) ->
    elements(Ready).

live_tag(#m{live = Live}) ->
    elements(maps:keys(Live)).

released_tag(#m{released = Released}) ->
    elements(maps:keys(Released)).

can_add(#m{consumers = Cs}) ->
    map_size(Cs) < length(?CTAGS).

%% The delivery target is deterministic: consumers hold distinct
%% priorities and parked consumers are out of the rotation.
eligible(#m{consumers = Cs}) ->
    [C || C := #{parked := false} <- Cs].

predicted_target(St) ->
    {_, CTag} = lists:max([{prio(C), C} || C <- eligible(St)]),
    CTag.

prio(CTag) ->
    %% <<"c1">> gets the highest priority.
    -binary:last(CTag).

timeout_ms(due) -> ?TIMEOUT_DUE;
timeout_ms(never) -> ?TIMEOUT_NEVER.

expire_offset(due) -> ?EXPIRE_DUE_OFFSET;
expire_offset(all) -> ?EXPIRE_ALL_OFFSET.

%% Preconditions. Repeated after shrinking, so they must re-derive
%% everything from the model state.

precondition(St, {call, _, cmd_add, [CTag, _]}) ->
    not is_map_key(CTag, St#m.consumers) andalso can_add(St);
precondition(St, {call, _, cmd_cancel, [CTag, _]}) ->
    is_map_key(CTag, St#m.consumers);
precondition(St, {call, _, cmd_deliver, [Msg]}) ->
    lists:member(Msg, St#m.ready) andalso eligible(St) =/= [];
precondition(St, {call, _, cmd_deliver_none, [Msg]}) ->
    lists:member(Msg, St#m.ready) andalso eligible(St) =:= [];
precondition(St, {call, _, cmd_ack_live, [Tag]}) ->
    is_map_key(Tag, St#m.live);
precondition(St, {call, _, cmd_requeue_live, [Tag]}) ->
    is_map_key(Tag, St#m.live);
precondition(St, {call, _, cmd_settle_released, [Tag]}) ->
    is_map_key(Tag, St#m.released);
precondition(St, {call, _, cmd_settle_stale, [Tag]}) ->
    is_map_key(Tag, St#m.released);
precondition(St, {call, _, cmd_erase_ch, []}) ->
    map_size(St#m.consumers) > 0;
precondition(_, _) ->
    true.

%% Model transitions. None of these inspect the command result, so the
%% model stays fully concrete during command generation.

next_state(St = #m{consumers = Cs}, _, {call, _, cmd_add, [CTag, Tier]}) ->
    St#m{consumers = Cs#{CTag => #{tier => Tier, parked => false}}};
next_state(St, _, {call, _, cmd_cancel, [CTag, Reason]}) ->
    #m{consumers = Cs, ready = Ready, live = Live,
       released = Released} = St,
    %% Cancelling drops the consumer's released debts. With reason
    %% 'remove' its live deliveries are returned and requeued; with
    %% 'cancel' they remain pending (and can still expire later).
    Live1 = case Reason of
                remove -> maps:filter(fun (_, {C, _}) -> C =/= CTag end, Live);
                cancel -> Live
            end,
    Returned = [Msg || Msg := {C, _} <- Live, C =:= CTag,
                       Reason =:= remove],
    St#m{consumers = maps:remove(CTag, Cs),
         ready = Returned ++ Ready,
         live = Live1,
         released = maps:filter(fun (_, C) -> C =/= CTag end, Released)};
next_state(St = #m{ready = Ready, live = Live}, _,
           {call, _, cmd_deliver, [Msg]}) ->
    CTag = predicted_target(St),
    #{CTag := #{tier := Tier}} = St#m.consumers,
    St#m{ready = lists:delete(Msg, Ready),
         live = Live#{Msg => {CTag, Tier}}};
next_state(St, _, {call, _, cmd_deliver_none, [_Msg]}) ->
    St;
next_state(St, _, {call, _, cmd_expire, [Which]}) ->
    #m{consumers = Cs0, ready = Ready, live = Live0,
       released = Released0} = St,
    Expired = expired_entries(St, Which),
    Holders = lists:usort([CTag || {_, CTag} <- Expired]),
    Live = maps:without([Tag || {Tag, _} <- Expired], Live0),
    %% A tag that expires again while its earlier settlement is still
    %% owed is reassigned to the new holder, releasing the earlier
    %% owner's unsatisfiable debt.
    Released = lists:foldl(fun ({Tag, CTag}, Acc) -> Acc#{Tag => CTag} end,
                           Released0, Expired),
    %% Holders of expired deliveries are parked until all of their
    %% released tags are settled; previously parked owners left without
    %% debts by the reassignment resume.
    Cs = maps:map(fun (CTag, Info = #{parked := Parked0}) ->
                          Parked = lists:member(CTag, Holders) orelse
                              (Parked0 andalso has_debt(CTag, Released)),
                          Info#{parked := Parked}
                  end, Cs0),
    St#m{consumers = Cs,
         ready = [Tag || {Tag, _} <- Expired] ++ Ready,
         live = Live,
         released = Released};
next_state(St, _, {call, _, cmd_listing, []}) ->
    St;
next_state(St = #m{live = Live, acked = Acked}, _,
           {call, _, cmd_ack_live, [Tag]}) ->
    St#m{live = maps:remove(Tag, Live), acked = [Tag | Acked]};
next_state(St = #m{ready = Ready, live = Live}, _,
           {call, _, cmd_requeue_live, [Tag]}) ->
    St#m{ready = [Tag | Ready], live = maps:remove(Tag, Live)};
next_state(St, _, {call, _, cmd_settle_released, [Tag]}) ->
    settle_released_state(St, Tag);
next_state(St = #m{ready = Ready, live = Live}, _,
           {call, _, cmd_settle_stale, [Tag]}) ->
    case Live of
        #{Tag := _} ->
            %% The tag was reused for a live redelivery, which wins:
            %% the requeue targets the live delivery and the released
            %% debt remains owed.
            St#m{ready = [Tag | Ready], live = maps:remove(Tag, Live)};
        _ ->
            settle_released_state(St, Tag)
    end;
next_state(_St = #m{acked = Acked}, _, {call, _, cmd_erase_ch, []}) ->
    %% The channel is gone: all pending deliveries are requeued, all
    %% consumers and released debts are forgotten.
    #m{ready = ?MSGS -- Acked, acked = Acked}.

settle_released_state(St, Tag) ->
    #m{consumers = Cs0, released = Released0} = St,
    Released = maps:remove(Tag, Released0),
    CTag = maps:get(Tag, Released0),
    Cs = case Cs0 of
             #{CTag := Info} ->
                 Cs0#{CTag := Info#{parked := has_debt(CTag, Released)}};
             _ ->
                 %% The owner was cancelled while parked.
                 Cs0
         end,
    St#m{consumers = Cs, released = Released}.

has_debt(CTag, Released) ->
    lists:any(fun (C) -> C =:= CTag end, maps:values(Released)).

%% Entries due at a given expiry horizon: 'due'-tier deliveries always,
%% 'never'-tier ones only when expiring everything.
expired_entries(#m{live = Live}, Which) ->
    lists:sort([{Tag, CTag} || Tag := {CTag, Tier} <- Live,
                               Which =:= all orelse Tier =:= due]).

%% Postconditions: every command result must match the model exactly.

postcondition(_, {call, _, cmd_add, _}, Res) ->
    Res =:= ok;
postcondition(St, {call, _, cmd_cancel, [CTag, Reason]}, Res) ->
    Returned = lists:sort([Tag || Tag := {C, _} <- St#m.live, C =:= CTag,
                                  Reason =:= remove]),
    Res =:= Returned;
postcondition(St, {call, _, cmd_deliver, [Msg]}, Res) ->
    Res =:= {delivered, predicted_target(St), Msg};
postcondition(_, {call, _, cmd_deliver_none, _}, Res) ->
    Res =:= undelivered;
postcondition(St, {call, _, cmd_expire, [Which]}, {Expired, Resumed}) ->
    Entries = expired_entries(St, Which),
    %% Parked owners whose last debt is reassigned by this expiry resume.
    Remaining = maps:filter(fun (T, _) ->
                                    not lists:keymember(T, 1, Entries)
                            end, St#m.released),
    PredictedResumed =
        lists:usort([Old || Tag := Old <- St#m.released,
                            lists:keymember(Tag, 1, Entries),
                            parked(St, Old),
                            not has_debt(Old, Remaining)]),
    Expired =:= Entries andalso Resumed =:= PredictedResumed;
postcondition(St, {call, _, cmd_listing, []}, Listing) ->
    %% Parked consumers are listed as timed_out, active ones as up.
    Predicted = lists:sort(
                  [{CTag, case Parked of
                              true -> timed_out;
                              false -> up
                          end} || CTag := #{parked := Parked}
                                      <- St#m.consumers]),
    Listing =:= Predicted;
postcondition(St, {call, _, cmd_ack_live, [Tag]}, {Matched, Resumed}) ->
    %% A live settlement matches the live delivery even when the tag
    %% also has a released debt: settling the debt instead would lose
    %% the live message. It never resumes anyone.
    _ = St,
    Matched =:= [Tag] andalso Resumed =:= [];
postcondition(_, {call, _, cmd_requeue_live, [Tag]}, {Matched, Resumed}) ->
    Matched =:= [Tag] andalso Resumed =:= [];
postcondition(St, {call, _, cmd_settle_released, [Tag]}, Resumed) ->
    Resumed =:= predicted_resume(St, Tag);
postcondition(St = #m{live = Live}, {call, _, cmd_settle_stale, [Tag]},
              {Matched, Resumed}) ->
    case is_map_key(Tag, Live) of
        true ->
            %% The live redelivery wins; nothing is drained from the
            %% released ledger and nothing resumes.
            Matched =:= [Tag] andalso Resumed =:= [];
        false ->
            Matched =:= [] andalso Resumed =:= predicted_resume(St, Tag)
    end;
postcondition(St, {call, _, cmd_erase_ch, []}, {AckTags, CTags}) ->
    AckTags =:= lists:sort(maps:keys(St#m.live)) andalso
        CTags =:= lists:sort(maps:keys(St#m.consumers)).

predicted_resume(St = #m{released = Released}, Tag) ->
    CTag = maps:get(Tag, Released),
    case parked(St, CTag) andalso
         not has_debt(CTag, maps:remove(Tag, Released)) of
        true -> [CTag];
        false -> []
    end.

parked(#m{consumers = Cs}, CTag) ->
    case Cs of
        #{CTag := #{parked := Parked}} -> Parked;
        _ -> false
    end.

%% Command implementations. The rabbit_queue_consumers state is kept in
%% the process dictionary so that commands are self-contained; the
%% channel records live there anyway.

cmd_add(CTag, Tier) ->
    QCState = rabbit_queue_consumers:add(
                self(), CTag, false, none, false, {simple_prefetch, 0},
                [{<<"x-priority">>, long, prio(CTag)}], <<"guest">>,
                timeout_ms(Tier), get(?SUT)),
    put(?SUT, QCState),
    ok.

cmd_cancel(CTag, Reason) ->
    {Acks, QCState} =
        rabbit_queue_consumers:remove(self(), CTag, Reason, get(?SUT)),
    put(?SUT, QCState),
    lists:sort(Acks).

cmd_deliver(Msg) ->
    FetchFun = fun (true) -> {{Msg, false, Msg}, ok} end,
    case rabbit_queue_consumers:deliver(FetchFun, ?QNAME, get(?SUT),
                                        false, none) of
        {delivered, _Blocked, ok, QCState} ->
            put(?SUT, QCState),
            receive
                {'$gen_cast',
                 {queue_event, _, {deliver, CTag, true,
                                   [{_QName, _Self, Msg, _Redelivered,
                                     Msg}]}}} ->
                    {delivered, CTag, Msg}
            after 0 ->
                {delivered, no_delivery_event, Msg}
            end;
        {undelivered, _Blocked, QCState} ->
            put(?SUT, QCState),
            undelivered
    end.

cmd_deliver_none(Msg) ->
    cmd_deliver(Msg).

cmd_expire(Which) ->
    Now = erlang:monotonic_time(millisecond) + expire_offset(Which),
    {Expired, Unblocked, QCState} =
        rabbit_queue_consumers:expire_acks(Now, get(?SUT)),
    put(?SUT, QCState),
    {lists:sort([{Tag, CTag} || {_Ch, CTag, Tags} <- Expired, Tag <- Tags]),
     ctags(Unblocked)}.

cmd_listing() ->
    lists:sort([{CTag, Status}
                || {_Ch, CTag, _Ack, _Prefetch, _Active, Status, _Args,
                    _User} <- rabbit_queue_consumers:all(get(?SUT))]).

cmd_ack_live(Tag) ->
    cmd_subtract(Tag).

cmd_requeue_live(Tag) ->
    cmd_subtract(Tag).

cmd_settle_stale(Tag) ->
    cmd_subtract(Tag).

cmd_subtract(Tag) ->
    {Matched, Resumed, QCState} =
        rabbit_queue_consumers:subtract_acks(self(), [Tag], get(?SUT)),
    put(?SUT, QCState),
    {lists:sort(Matched), ctags(Resumed)}.

cmd_settle_released(Tag) ->
    {Resumed, QCState} =
        rabbit_queue_consumers:settle_released(self(), [Tag], get(?SUT)),
    put(?SUT, QCState),
    ctags(Resumed).

cmd_erase_ch() ->
    {AckTags, CTags, QCState} =
        rabbit_queue_consumers:erase_ch(self(), get(?SUT)),
    put(?SUT, QCState),
    {lists:sort(AckTags), lists:sort(CTags)}.

ctags(Consumers) ->
    lists:usort([rabbit_queue_consumers:consumer_tag(C)
                 || {_Ch, C} <- Consumers]).
