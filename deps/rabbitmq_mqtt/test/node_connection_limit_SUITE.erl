%% This Source Code Form is subject to the terms of the Mozilla Public
%% License, v. 2.0. If a copy of the MPL was not distributed with this
%% file, You can obtain one at https://mozilla.org/MPL/2.0/.
%%
%% Copyright (c) 2007-2026 Broadcom. All Rights Reserved. The term “Broadcom” refers to Broadcom Inc. and/or its subsidiaries. All rights reserved.
%%

-module(node_connection_limit_SUITE).

-include_lib("common_test/include/ct.hrl").
-include_lib("eunit/include/eunit.hrl").
-include_lib("rabbitmq_ct_helpers/include/rabbit_assert.hrl").

-compile(export_all).

all() ->
    [
     {group, tests}
    ].

groups() ->
    [
     {tests, [], [total_connection_limit_spans_protocols]}
    ].

suite() ->
    [{timetrap, {minutes, 3}}].

%% -------------------------------------------------------------------
%% Testsuite setup/teardown.
%% -------------------------------------------------------------------

init_per_suite(Config) ->
    rabbit_ct_helpers:log_environment(),
    Config1 = rabbit_ct_helpers:set_config(
                Config,
                [{rmq_nodename_suffix, ?MODULE},
                 {start_rmq_with_plugins_disabled, true}]),
    Config2 = rabbit_ct_helpers:run_setup_steps(
                Config1,
                rabbit_ct_broker_helpers:setup_steps() ++
                    rabbit_ct_client_helpers:setup_steps()),
    util:enable_plugin(Config2, rabbitmq_mqtt),
    Config2.

end_per_suite(Config) ->
    rabbit_ct_helpers:run_teardown_steps(
      Config,
      rabbit_ct_client_helpers:teardown_steps() ++
          rabbit_ct_broker_helpers:teardown_steps()).

init_per_group(_Group, Config) ->
    Config.

end_per_group(_Group, Config) ->
    Config.

init_per_testcase(Testcase, Config) ->
    rabbit_ct_helpers:testcase_started(Config, Testcase).

end_per_testcase(Testcase, Config) ->
    set_total_limit(Config, infinity),
    rabbit_ct_helpers:testcase_finished(Config, Testcase).

%% -------------------------------------------------------------------
%% Test cases
%% -------------------------------------------------------------------

%% connection_max_per_node is a single node-wide ceiling. An AMQP 0-9-1 and an
%% MQTT connection must both count toward it and both be refused once it is
%% reached, proving the limit spans protocols rather than any one listener.
total_connection_limit_spans_protocols(Config) ->
    set_total_limit(Config, 2),

    Amqp = rabbit_ct_client_helpers:open_unmanaged_connection(Config, 0),
    true = is_pid(Amqp),
    Mqtt = util:connect(<<"total-limit-mqtt">>, Config),
    ?awaitMatch(2, total_connection_count(Config), 30000),

    {error, not_allowed} =
        rabbit_ct_client_helpers:open_unmanaged_connection(Config, 0),
    {MqttRefused, Connect} =
        util:start_client(<<"total-limit-mqtt-refused">>, Config, 0, []),
    true = unlink(MqttRefused),
    ?assertMatch({error, _}, Connect(MqttRefused)),

    ok = emqtt:disconnect(Mqtt),
    ok = rabbit_ct_client_helpers:close_connection(Amqp),
    ok.

%% -------------------------------------------------------------------
%% Implementation
%% -------------------------------------------------------------------

set_total_limit(Config, Value) ->
    ok = rabbit_ct_broker_helpers:rpc(Config, 0, application, set_env,
                                      [rabbit, connection_max_per_node, Value]).

total_connection_count(Config) ->
    rabbit_ct_broker_helpers:rpc(Config, 0, rabbit_networking,
                                 total_connection_count, []).
