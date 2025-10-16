-module(snapshot_divergence_SUITE).
-moduledoc "Tests showing effects of shuffling from crashes of >32 consumers".

-compile([export_all, nowarn_export_all]).

-include_lib("common_test/include/ct.hrl").
-include_lib("eunit/include/eunit.hrl").
-include_lib("amqp_client/include/amqp_client.hrl").
-include_lib("rabbitmq_ct_helpers/include/rabbit_assert.hrl").

all() ->
    [{group, all_tests}].

groups() ->
    [{all_tests, [], all_tests()}].

all_tests() ->
    [
        message_shuffle
    ].

%% -------------------------------------------------------------------
%% Testsuite setup/teardown.
%% -------------------------------------------------------------------

init_per_suite(Config) ->
    rabbit_ct_helpers:log_environment(),
    Config1 = rabbit_ct_helpers:set_config(Config, [
        {rmq_nodename_suffix, ?MODULE},
        {rmq_nodes_count, 3},
        {rmq_nodes_clustered, true}
    ]),
    rabbit_ct_helpers:run_setup_steps(
        Config1,
        rabbit_ct_broker_helpers:setup_steps() ++
            rabbit_ct_client_helpers:setup_steps()
    ).

end_per_suite(Config) ->
    rabbit_ct_helpers:run_teardown_steps(
        Config,
        rabbit_ct_client_helpers:teardown_steps() ++
            rabbit_ct_broker_helpers:teardown_steps()
    ).

init_per_group(_Group, Config) ->
    Config.

end_per_group(_, Config) ->
    Config.

init_per_testcase(Testcase, Config) ->
    rabbit_ct_helpers:testcase_started(Config, Testcase).

end_per_testcase(Testcase, Config) ->
    rabbit_ct_helpers:testcase_finished(Config, Testcase).

%% -------------------------------------------------------------------
%% Testcases.
%% -------------------------------------------------------------------

message_shuffle(Config) ->
    [Server0, Server1, _Server2] =
        rabbit_ct_broker_helpers:get_node_configs(Config, nodename),

    {PublishConn, PublishCh} = rabbit_ct_client_helpers:open_connection_and_channel(Config),
    Q = <<"qq">>,
    RaName = binary_to_atom(<<"%2F_", Q/binary>>, utf8),

    %% Create a QQ called 'qq' and publish 33 messages there.
    amqp_channel:call(PublishCh, #'confirm.select'{}),
    declare(PublishCh, Q, [{<<"x-queue-type">>, longstr, <<"quorum">>}]),
    [publish(PublishCh, <<>>, Q, iolist_to_binary(io_lib:format("~b", [N]))) || N <- lists:seq(1, 33)],
    true = amqp_channel:wait_for_confirms(PublishCh),
    rabbit_ct_client_helpers:close_channel(PublishCh),
    rabbit_ct_client_helpers:close_connection(PublishConn),

    {ShufflePid, ShuffleRef} = spawn_monitor(fun() ->
        Conn = rabbit_ct_client_helpers:open_unmanaged_connection(Config),
        link(Conn),
        {ok, Ch} = amqp_connection:open_channel(Conn),
        link(Ch),
        %% Get 33 messages. Then exit, closing the channel and connection.
        %% This causes the messages to be returned in shuffled order.
        _ = basic_get(Ch, Q, 33),
        ok
    end),

    receive
        {'DOWN', ShuffleRef, process, ShufflePid, normal} ->
            ok;
        {'DOWN', ShuffleRef, process, ShufflePid, Reason} ->
            ct:fail("Shuffle failed: ~p", [Reason])
    end,

    %% The returns queue is shuffle now. Check out a few messages, transfer
    %% leadership in the queue to a different replica, then ack them.
    {_ConsumeConn, ConsumeCh} = rabbit_ct_client_helpers:open_connection_and_channel(Config),
    {LastTag, FirstMsgs} = basic_get(ConsumeCh, Q, 5),
    FirstMsgs1 = [binary_to_integer(B) || B <- FirstMsgs],
    ct:pal("First 5 messages read: ~w", [FirstMsgs1]),

    ServerId0 = {RaName, Server0},
    ServerId1 = {RaName, Server1},
    ct:pal(
        "transfer leadership from ~w to ~w: ~p",
        [
            ServerId0,
            ServerId1,
            rabbit_ct_broker_helpers:rpc(
                Config,
                0,
                ra,
                transfer_leadership,
                [ServerId0, ServerId1]
            )
        ]
    ),

    %% Ack the outstanding messages and consume the rest.
    amqp_channel:cast(ConsumeCh, #'basic.ack'{
        delivery_tag = LastTag,
        multiple = true
    }),

    {LastTag1, RestMsgs} = basic_get(ConsumeCh, Q, 33 - 5),
    amqp_channel:cast(ConsumeCh, #'basic.ack'{
        delivery_tag = LastTag1,
        multiple = true
    }),
    RestMsgs1 = [binary_to_integer(B) || B <- RestMsgs],
    ct:pal("Remaining messages read: ~w", [RestMsgs1]),

    ConsumedMsgs = FirstMsgs1 ++ RestMsgs1,
    DroppedMsgs = lists:seq(1, 33) -- ConsumedMsgs,
    ct:pal("Dropped messages: ~w", [DroppedMsgs]),
    DupedMsgs = ConsumedMsgs -- lists:seq(1, 33),
    ct:pal("Duplicated messages: ~w", [DupedMsgs]),

    ?assertNotEqual([], DroppedMsgs),
    ?assertNotEqual([], DupedMsgs),

    ok.

%% -------------------------------------------------------------------

declare(Ch, Q, Args) ->
    amqp_channel:call(Ch, #'queue.declare'{
        queue = Q,
        durable = true,
        auto_delete = false,
        arguments = Args
    }).

publish(Ch, X, Key, Payload) when is_binary(Payload) ->
    publish(Ch, X, Key, #amqp_msg{payload = Payload});
publish(Ch, X, Key, Msg = #amqp_msg{}) ->
    amqp_channel:cast(
        Ch,
        #'basic.publish'{
            exchange = X,
            routing_key = Key
        },
        Msg
    ).

basic_get(Ch, Q, N) ->
    basic_get(Ch, Q, N, undefined, []).

basic_get(_Ch, _Q, 0, LastTag, Acc) ->
    {LastTag, lists:reverse(Acc)};
basic_get(Ch, Q, N, Tag0, Acc) ->
    case amqp_channel:call(Ch, #'basic.get'{queue = Q}) of
        {#'basic.get_ok'{delivery_tag = Tag}, #amqp_msg{payload = Msg}} ->
            basic_get(Ch, Q, N - 1, Tag, [Msg | Acc]);
        #'basic.get_empty'{} ->
            basic_get(Ch, Q, N - 1, Tag0, Acc)
    end.
