%% This Source Code Form is subject to the terms of the Mozilla Public
%% License, v. 2.0. If a copy of the MPL was not distributed with this
%% file, You can obtain one at https://mozilla.org/MPL/2.0/.
%%
%% Copyright (c) 2007-2026 Broadcom. All Rights Reserved. The term “Broadcom” refers to Broadcom Inc. and/or its subsidiaries. All rights reserved.
%%

-module(unit_queue_consumers_SUITE).

-include_lib("eunit/include/eunit.hrl").

-compile(export_all).

all() ->
    [
        is_same,
        get_consumer,
        get,
        list_consumers,
        list_consumers_reports_blocked,
        list_consumers_sac_active_overrides_blocked,
        list_consumers_sac_inactive_overrides_blocked,
        expire_acks_parks_consumer,
        expire_acks_reassigns_reused_tag,
        settle_released_targets_timed_out_entry,
        settle_resumes_parked_consumer
    ].

is_same(_Config) ->
    ?assertEqual(
        true,
        rabbit_queue_consumers:is_same(
            self(), <<"1">>,
            consumer(self(), <<"1">>)
        )),
    ?assertEqual(
        false,
        rabbit_queue_consumers:is_same(
            self(), <<"1">>,
            consumer(self(), <<"2">>)
        )),
    Pid = spawn(?MODULE, function_for_process, []),
    Pid ! whatever,
    ?assertEqual(
        false,
        rabbit_queue_consumers:is_same(
            self(), <<"1">>,
            consumer(Pid, <<"1">>)
        )),
    ok.

get(_Config) ->
    Pid = spawn(?MODULE, function_for_process, []),
    Pid ! whatever,
    State = state(consumers([consumer(self(), <<"1">>), consumer(Pid, <<"2">>), consumer(self(), <<"3">>)])),
    {Pid, {consumer, <<"2">>, _, _, _, _, _}} =
        rabbit_queue_consumers:get(Pid, <<"2">>, State),
    ?assertEqual(
        undefined,
        rabbit_queue_consumers:get(self(), <<"2">>, State)
    ),
    ?assertEqual(
        undefined,
        rabbit_queue_consumers:get(Pid, <<"1">>, State)
    ),
    ok.

get_consumer(_Config) ->
    Pid = spawn(unit_queue_consumers_SUITE, function_for_process, []),
    Pid ! whatever,
    State = state(consumers([consumer(self(), <<"1">>), consumer(Pid, <<"2">>), consumer(self(), <<"3">>)])),
    {_Pid, {consumer, _, _, _, _, _, _}} =
        rabbit_queue_consumers:get_consumer(State),
    ?assertEqual(
        undefined,
        rabbit_queue_consumers:get_consumer(state(consumers([])))
    ),
    ok.

list_consumers(_Config) ->
    State = state(consumers([consumer(self(), <<"1">>), consumer(self(), <<"2">>), consumer(self(), <<"3">>)])),
    Consumer = rabbit_queue_consumers:get_consumer(State),
    {_Pid, ConsumerRecord} = Consumer,
    CTag = rabbit_queue_consumers:consumer_tag(ConsumerRecord),
    ConsumersWithSingleActive = rabbit_queue_consumers:all(State, Consumer, true),
    ?assertEqual(3, length(ConsumersWithSingleActive)),
    lists:foldl(fun({Pid, Tag, _, _, Active, ActivityStatus, _, _}, _Acc) ->
        ?assertEqual(self(), Pid),
        case Tag of
            CTag ->
                ?assert(Active),
                ?assertEqual(single_active, ActivityStatus);
            _ ->
                ?assertNot(Active),
                ?assertEqual(waiting, ActivityStatus)
        end
              end, [], ConsumersWithSingleActive),
    ConsumersNoSingleActive = rabbit_queue_consumers:all(State, none, false),
    ?assertEqual(3, length(ConsumersNoSingleActive)),
    lists:foldl(fun({Pid, _, _, _, Active, ActivityStatus, _, _}, _Acc) ->
                    ?assertEqual(self(), Pid),
                    ?assert(Active),
                    ?assertEqual(up, ActivityStatus)
                end, [], ConsumersNoSingleActive),
    ok.

list_consumers_reports_blocked(_Config) ->
    ChPid = self(),
    Consumer = consumer(ChPid, <<"blocked-tag">>),
    install_ch_record(ChPid, [Consumer]),
    try
        State = state(consumers([])),
        Result = rabbit_queue_consumers:all(State, none, false),
        ?assertEqual(1, length(Result)),
        [{Pid, Tag, _Ack, _Pref, Active, ActivityStatus, _Args, _User}] = Result,
        ?assertEqual(ChPid, Pid),
        ?assertEqual(<<"blocked-tag">>, Tag),
        ?assert(Active),
        ?assertEqual(blocked, ActivityStatus)
    after
        uninstall_ch_record(ChPid)
    end.

list_consumers_sac_active_overrides_blocked(_Config) ->
    ChPid = self(),
    Consumer = consumer(ChPid, <<"sac-tag">>),
    install_ch_record(ChPid, [Consumer]),
    try
        State = state(consumers([])),
        Result = rabbit_queue_consumers:all(State, Consumer, true),
        ?assertEqual(1, length(Result)),
        [{_Pid, _Tag, _Ack, _Pref, Active, ActivityStatus, _Args, _User}] = Result,
        ?assert(Active),
        ?assertEqual(single_active, ActivityStatus)
    after
        uninstall_ch_record(ChPid)
    end.

list_consumers_sac_inactive_overrides_blocked(_Config) ->
    ChPid = self(),
    HolderConsumer = consumer(ChPid, <<"sac-holder">>),
    OtherConsumer  = consumer(ChPid, <<"sac-waiting">>),
    install_ch_record(ChPid, [OtherConsumer]),
    try
        State = state(consumers([])),
        Result = rabbit_queue_consumers:all(State, HolderConsumer, true),
        ?assertEqual(1, length(Result)),
        [{_Pid, _Tag, _Ack, _Pref, Active, ActivityStatus, _Args, _User}] = Result,
        ?assertNot(Active),
        ?assertEqual(waiting, ActivityStatus)
    after
        uninstall_ch_record(ChPid)
    end.

%% Expiring a delivery whose deadline has passed reports it, parks the
%% consumer and keeps deliveries with future deadlines tracked.
expire_acks_parks_consumer(_Config) ->
    ChPid = self(),
    Now = erlang:monotonic_time(millisecond),
    Entry = consumer(ChPid, <<"ctag1">>),
    AckTags = lqueue:in({2, <<"ctag1">>, Now + 60_000},
                        lqueue:in({1, <<"ctag1">>, Now - 1}, lqueue:new())),
    install_ch_record(ChPid, [], #{acktags => AckTags,
                                   next_deadline => Now - 1}),
    try
        State0 = state(consumers([Entry])),
        {Expired, Unblocked, State1} =
            rabbit_queue_consumers:expire_acks(Now, State0),
        ?assertEqual([{ChPid, <<"ctag1">>, [1]}], Expired),
        ?assertEqual([], Unblocked),
        %% The consumer is withheld from further deliveries.
        ?assertMatch([{ChPid, <<"ctag1">>, _, _, false, timed_out, _, _}],
                     rabbit_queue_consumers:all(State1, none, false)),
        %% The delivery with a future deadline remains tracked.
        ?assert(rabbit_queue_consumers:holds_acks(ChPid, <<"ctag1">>))
    after
        uninstall_ch_record(ChPid)
    end.

%% A tag value that expires again while an earlier timed-out entry for it
%% is still unsettled is reassigned; the earlier owner's unsatisfiable
%% debt is released so that it does not stay parked forever.
expire_acks_reassigns_reused_tag(_Config) ->
    ChPid = self(),
    Now = erlang:monotonic_time(millisecond),
    {_, Consumer1} = consumer(ChPid, <<"ctag1">>),
    Entry2 = consumer(ChPid, <<"ctag2">>),
    install_ch_record(ChPid, [],
                      #{acktags => lqueue:in({5, <<"ctag2">>, Now - 1},
                                             lqueue:new()),
                        next_deadline => Now - 1,
                        timed_out_acks => #{5 => <<"ctag1">>},
                        timed_out_consumers => #{<<"ctag1">> => {Consumer1, 1}}}),
    try
        State0 = state(consumers([Entry2])),
        {Expired, _Unblocked, State1} =
            rabbit_queue_consumers:expire_acks(Now, State0),
        ?assertEqual([{ChPid, <<"ctag2">>, [5]}], Expired),
        Infos = lists:sort(rabbit_queue_consumers:all(State1, none, false)),
        ?assertMatch([{ChPid, <<"ctag1">>, _, _, _, up, _, _},
                      {ChPid, <<"ctag2">>, _, _, false, timed_out, _, _}],
                     Infos)
    after
        uninstall_ch_record(ChPid)
    end.

%% A tag value is reused when a requeued message is delivered again, so a
%% tag can be pending both as a live delivery and as a timed-out one.
%% settle_released/3 must resolve to the timed-out entry and never to the
%% live redelivery, which another consumer is still processing.
settle_released_targets_timed_out_entry(_Config) ->
    ChPid = self(),
    Deadline = erlang:monotonic_time(millisecond) + 60_000,
    {_, Consumer1} = consumer(ChPid, <<"ctag1">>),
    install_ch_record(ChPid, [],
                      #{acktags => lqueue:in({5, <<"ctag2">>, Deadline},
                                             lqueue:new()),
                        timed_out_acks => #{5 => <<"ctag1">>},
                        timed_out_consumers => #{<<"ctag1">> => {Consumer1, 1}}}),
    try
        {Resumed, _State1} =
            rabbit_queue_consumers:settle_released(ChPid, [5],
                                                   state(consumers([]))),
        %% The timed-out entry is settled, not the live redelivery.
        ?assertMatch([{ChPid, {consumer, <<"ctag1">>, _, _, _, _, _}}], Resumed),
        ?assert(rabbit_queue_consumers:holds_acks(ChPid, <<"ctag2">>)),
        %% The live redelivery is settled by a regular settlement, which
        %% must leave the (now empty) timed-out state alone.
        {Matched, [], _State2} =
            rabbit_queue_consumers:subtract_acks(ChPid, [5],
                                                 state(consumers([]))),
        ?assertEqual([5], Matched),
        ?assertNot(rabbit_queue_consumers:holds_acks(ChPid, <<"ctag2">>))
    after
        uninstall_ch_record(ChPid)
    end.

%% A parked consumer resumes once all of its timed-out tags are settled,
%% and not before. Settling through subtract_acks/3 exercises the
%% fallback used by settlements that are not partitioned by the channel
%% (for example AMQP 1.0 sessions).
settle_resumes_parked_consumer(_Config) ->
    ChPid = self(),
    {_, Consumer1} = consumer(ChPid, <<"ctag1">>),
    install_ch_record(ChPid, [],
                      #{timed_out_acks => #{7 => <<"ctag1">>, 8 => <<"ctag1">>},
                        timed_out_consumers => #{<<"ctag1">> => {Consumer1, 2}}}),
    try
        State0 = state(consumers([])),
        {[], [], State1} =
            rabbit_queue_consumers:subtract_acks(ChPid, [7], State0),
        ?assertEqual(undefined, rabbit_queue_consumers:get_consumer(State1)),
        {[], Resumed, State2} =
            rabbit_queue_consumers:subtract_acks(ChPid, [8], State1),
        ?assertEqual([{ChPid, Consumer1}], Resumed),
        %% The consumer rejoined the rotation.
        ?assertEqual({ChPid, Consumer1},
                     rabbit_queue_consumers:get_consumer(State2))
    after
        uninstall_ch_record(ChPid)
    end.

%% #cr field order: ch_pid, monitor_ref, acktags, consumer_count,
%% blocked_consumers, limiter, unsent_message_count, link_states,
%% timed_out_acks, timed_out_consumers, next_deadline.
install_ch_record(ChPid, ConsumerEntries) ->
    install_ch_record(ChPid, ConsumerEntries, #{}).

install_ch_record(ChPid, ConsumerEntries, Overrides) ->
    BlockedQ = lists:foldl(fun (C, Acc) -> priority_queue:in(C, Acc) end,
                           priority_queue:new(), ConsumerEntries),
    Get = fun (Key, Default) -> maps:get(Key, Overrides, Default) end,
    %% The consumer count is at least 1 so that the record is not erased
    %% (and its undefined monitor reference demonitored) mid-test.
    CR = {cr, ChPid, undefined,
          Get(acktags, lqueue:new()),
          Get(consumer_count, max(length(ConsumerEntries), 1)),
          BlockedQ,
          rabbit_limiter:client(undefined),
          0, #{},
          Get(timed_out_acks, #{}),
          Get(timed_out_consumers, #{}),
          Get(next_deadline, infinity)},
    put({ch, ChPid}, CR),
    ok.

uninstall_ch_record(ChPid) ->
    _ = erase({ch, ChPid}),
    ok.

consumers([]) ->
    priority_queue:new();
consumers(Consumers) ->
    consumers(Consumers, priority_queue:new()).

consumers([H], Q) ->
    priority_queue:in(H, Q);
consumers([H | T], Q) ->
    consumers(T, priority_queue:in(H, Q)).


consumer(Pid, ConsumerTag) ->
    {Pid, {consumer, ConsumerTag, true, 1, [], <<"guest">>, 1_800_000}}.

%% #state field order: consumers, use, next_deadline.
state(Consumers) ->
    {state, Consumers,
     {active, erlang:monotonic_time(microsecond), 1.0}, infinity}.

function_for_process() ->
    receive
        _ -> ok
    end.
