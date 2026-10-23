%% This Source Code Form is subject to the terms of the Mozilla Public
%% License, v. 2.0. If a copy of the MPL was not distributed with this
%% file, You can obtain one at https://mozilla.org/MPL/2.0/.
%%
%% Copyright (c) 2007-2026 Broadcom. All Rights Reserved. The term "Broadcom" refers to Broadcom Inc. and/or its subsidiaries. All rights reserved.
%%

%% Tests `stomp.max_connections`. Web STOMP coverage is in the
%% rabbitmq_web_stomp suite of the same name.

-module(node_connection_limit_SUITE).

-compile([export_all, nowarn_export_all]).

-include_lib("proper/include/proper.hrl").
-include_lib("common_test/include/ct.hrl").
-include_lib("eunit/include/eunit.hrl").
-include_lib("rabbitmq_ct_helpers/include/rabbit_assert.hrl").
-include("rabbit_stomp.hrl").
-include("rabbit_stomp_frame.hrl").

-define(TIMEOUT, 5_000).

all() ->
    [
     {group, with_tls},
     {group, plain_only}
    ].

groups() ->
    [
     {with_tls, [], [
                     cross_listener_tcp_tls
                    ]},
     {plain_only, [], [
                       boundary_and_decrement,
                       infinity,
                       infinity_after_setting_limit,
                       rejects_when_count_equals_limit,
                       limit_zero_rejects_first_connection,
                       count_decrements_on_disconnect,
                       total_limit_refuses_stomp,
                       prop_admits_min_attempts_limit
                      ]}
    ].

init_per_suite(Config) ->
    rabbit_ct_helpers:log_environment(),
    Config.

end_per_suite(Config) -> Config.

init_per_group(with_tls, Config) ->
    Suffix = rabbit_ct_helpers:testcase_absname(Config, "", "-"),
    Config1 = rabbit_ct_helpers:set_config(Config, [
        {rmq_nodename_suffix, Suffix},
        {rmq_certspwd, "bunnychow"},
        {rabbitmq_ct_tls_verify, verify_none}
    ]),
    rabbit_ct_helpers:run_setup_steps(Config1,
        rabbit_ct_broker_helpers:setup_steps() ++
        rabbit_ct_client_helpers:setup_steps());
init_per_group(plain_only, Config) ->
    Suffix = rabbit_ct_helpers:testcase_absname(Config, "", "-"),
    Config1 = rabbit_ct_helpers:set_config(Config, [
        {rmq_nodename_suffix, Suffix}
    ]),
    rabbit_ct_helpers:run_setup_steps(Config1,
        rabbit_ct_broker_helpers:setup_steps() ++
        rabbit_ct_client_helpers:setup_steps()).

end_per_group(_, Config) ->
    rabbit_ct_helpers:run_teardown_steps(Config,
        rabbit_ct_client_helpers:teardown_steps() ++
        rabbit_ct_broker_helpers:teardown_steps()).

init_per_testcase(Testcase, Config) ->
    rabbit_ct_helpers:testcase_started(Config, Testcase).

end_per_testcase(Testcase, Config) ->
    unset_max_connections(Config),
    set_total_limit(Config, infinity),
    await_local_count(Config, 0),
    rabbit_ct_helpers:testcase_finished(Config, Testcase).

%% --- test cases ---

boundary_and_decrement(Config) ->
    set_max_connections(Config, 2),
    {ok, S1} = connect(Config, plain),
    {ok, S2} = connect(Config, plain),
    await_local_count(Config, 2),
    ?assertEqual({error, refused}, attempt(Config, plain)),
    close(S1, plain),
    await_local_count(Config, 1),
    {ok, S3} = connect(Config, plain),
    close(S2, plain),
    close(S3, plain),
    await_local_count(Config, 0),
    ok.

cross_listener_tcp_tls(Config) ->
    %% Same limit covers plain TCP and TLS. Dual-stack IPv4/IPv6 is the
    %% same shape — two Ranch listeners, one `pg` scope.
    set_max_connections(Config, 2),
    {ok, S1} = connect(Config, plain),
    {ok, S2} = connect(Config, tls),
    ?assertEqual({error, refused}, attempt(Config, plain)),
    ?assertEqual({error, refused}, attempt(Config, tls)),
    close(S1, plain),
    close(S2, tls),
    await_local_count(Config, 0),
    ok.

infinity(Config) ->
    set_max_connections(Config, infinity),
    Socks = [begin {ok, S} = connect(Config, plain), S end
             || _ <- lists:seq(1, 5)],
    await_local_count(Config, 5),
    [close(S, plain) || S <- Socks],
    await_local_count(Config, 0),
    ok.

infinity_after_setting_limit(Config) ->
    set_max_connections(Config, 1),
    {ok, S1} = connect(Config, plain),
    ?assertEqual({error, refused}, attempt(Config, plain)),
    set_max_connections(Config, infinity),
    Socks = [begin {ok, S} = connect(Config, plain), S end
             || _ <- lists:seq(1, 4)],
    [close(S, plain) || S <- [S1 | Socks]],
    await_local_count(Config, 0),
    ok.

rejects_when_count_equals_limit(Config) ->
    set_max_connections(Config, 1),
    {ok, S1} = connect(Config, plain),
    ?assertEqual({error, refused}, attempt(Config, plain)),
    close(S1, plain),
    await_local_count(Config, 0),
    ok.

limit_zero_rejects_first_connection(Config) ->
    set_max_connections(Config, 0),
    ?assertEqual({error, refused}, attempt(Config, plain)),
    await_local_count(Config, 0),
    ok.

count_decrements_on_disconnect(Config) ->
    %% Slot is freed by the reader process exiting; the DISCONNECT frame
    %% is not required.
    set_max_connections(Config, 2),
    {ok, S1} = connect(Config, plain),
    {ok, S2} = connect(Config, plain),
    gen_tcp:close(S1),
    await_local_count(Config, 1),
    {ok, S3} = connect(Config, plain),
    close(S2, plain),
    close(S3, plain),
    await_local_count(Config, 0),
    ok.

total_limit_refuses_stomp(Config) ->
    set_total_limit(Config, 1),
    {ok, S1} = connect(Config, plain),
    {ok, Sock} = open_socket(Config, plain),
    ok = gen_tcp:send(Sock, connect_frame()),
    {ok, Data} = gen_tcp:recv(Sock, 0, ?TIMEOUT),
    ?assertEqual(<<"ERROR">>, parse_command(Data)),
    ?assertNotEqual(nomatch, binary:match(Data, <<"total node connection limit">>)),
    gen_tcp:close(Sock),
    close(S1, plain),
    await_local_count(Config, 0),
    ok.

%% For any (Limit, N), N CONNECT attempts admit min(N, Limit), or N if
%% Limit is infinity.
prop_admits_min_attempts_limit(Config) ->
    ok = rabbit_ct_proper_helpers:run_proper(
           fun prop_admits/1, [Config], 15).

prop_admits(Config) ->
    ?FORALL({Limit, N},
            {oneof([infinity, range(0, 4)]), range(0, 6)},
            begin
                set_max_connections(Config, Limit),
                await_local_count(Config, 0),
                Results = [open_attempt(Config, plain) || _ <- lists:seq(1, N)],
                Opened = [S || {ok, S} <- Results],
                Expected = expected_admits(Limit, N),
                Actual = length(Opened),
                [close(S, plain) || S <- Opened],
                await_local_count(Config, 0),
                Actual =:= Expected
            end).

expected_admits(infinity, N) -> N;
expected_admits(Limit, N) when is_integer(Limit) -> min(N, Limit).

%% --- broker-side helpers ---

set_max_connections(Config, Value) ->
    ok = rabbit_ct_broker_helpers:rpc(
           Config, 0, application, set_env,
           [rabbitmq_stomp, max_connections, Value]).

set_total_limit(Config, Value) ->
    ok = rabbit_ct_broker_helpers:rpc(
           Config, 0, application, set_env,
           [rabbit, connection_max_per_node, Value]).

unset_max_connections(Config) ->
    ok = rabbit_ct_broker_helpers:rpc(
           Config, 0, application, unset_env,
           [rabbitmq_stomp, max_connections]).

count_local(Config) ->
    rabbit_ct_broker_helpers:rpc(
      Config, 0, rabbit_stomp, local_connection_count, []).

await_local_count(Config, Expected) ->
    ?awaitMatch(Expected, count_local(Config), 30_000).

%% --- client-side helpers, parameterised on transport ---

connect(Config, Transport) ->
    {ok, Sock} = open_socket(Config, Transport),
    ok = (mod(Transport)):send(Sock, connect_frame()),
    {ok, _} = recv_connected(Sock, Transport),
    {ok, Sock}.

attempt(Config, Transport) ->
    case open_attempt(Config, Transport) of
        {ok, Sock} ->
            close(Sock, Transport),
            ok;
        refused ->
            {error, refused}
    end.

open_attempt(Config, Transport) ->
    Mod = mod(Transport),
    {ok, Sock} = open_socket(Config, Transport),
    ok = Mod:send(Sock, connect_frame()),
    case Mod:recv(Sock, 0, ?TIMEOUT) of
        {ok, Data} ->
            case parse_command(Data) of
                <<"CONNECTED">> -> {ok, Sock};
                <<"ERROR">> ->
                    Mod:close(Sock),
                    refused
            end;
        {error, _} ->
            Mod:close(Sock),
            refused
    end.

close(Sock, Transport) ->
    Mod = mod(Transport),
    _ = (catch Mod:send(Sock, <<"DISCONNECT\n\n\0">>)),
    _ = Mod:close(Sock),
    ok.

mod(plain) -> gen_tcp;
mod(tls)   -> ssl.

open_socket(Config, plain) ->
    Port = rabbit_ct_broker_helpers:get_node_config(Config, 0, tcp_port_stomp),
    gen_tcp:connect("localhost", Port,
                    [binary, {active, false}, {packet, raw}]);
open_socket(Config, tls) ->
    Port = rabbit_ct_broker_helpers:get_node_config(Config, 0, tcp_port_stomp_tls),
    {ok, _} = application:ensure_all_started(ssl),
    ssl:connect("localhost", Port,
                [binary, {active, false}, {packet, raw},
                 {verify, verify_none}], ?TIMEOUT).

connect_frame() ->
    <<"CONNECT\naccept-version:1.2\nhost:/\nlogin:guest\npasscode:guest\n\n\0">>.

recv_connected(Sock, Transport) ->
    Mod = mod(Transport),
    case Mod:recv(Sock, 0, ?TIMEOUT) of
        {ok, Data} ->
            case parse_command(Data) of
                <<"CONNECTED">> -> {ok, Data};
                Other -> {error, {unexpected, Other}}
            end;
        {error, _} = E -> E
    end.

parse_command(Data) ->
    case rabbit_stomp_frame:parse(Data, rabbit_stomp_frame:initial_state()) of
        {ok, #stomp_frame{command = Cmd}, _Rest} ->
            rabbit_data_coercion:to_binary(Cmd);
        _ ->
            <<"PARSE_ERROR">>
    end.
