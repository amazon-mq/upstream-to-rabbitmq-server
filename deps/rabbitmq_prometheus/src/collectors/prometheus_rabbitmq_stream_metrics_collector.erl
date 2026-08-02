%% This Source Code Form is subject to the terms of the Mozilla Public
%% License, v. 2.0. If a copy of the MPL was not distributed with this
%% file, You can obtain one at https://mozilla.org/MPL/2.0/.
%%
%% Copyright (c) 2007-2026 Broadcom. All Rights Reserved. The term “Broadcom” refers to Broadcom Inc. and/or its subsidiaries. All rights reserved.
%%

%% Exposes the node-wide histograms osiris records for the sizes of the
%% entries, sub-batches and chunks written to streams on this node.
%%
%% These are aggregates rather than per-stream series, so they are cheap
%% enough to belong in the default registry: three metric families of a
%% handful of buckets each, whatever the number of streams.
-module(prometheus_rabbitmq_stream_metrics_collector).

-behaviour(prometheus_collector).
-include_lib("prometheus/include/prometheus.hrl").

-export([register/0,
         deregister_cleanup/1,
         collect_mf/2]).

-define(METRIC_NAME_PREFIX, "rabbitmq_stream_").

%% the seshat group osiris registers its metrics in
-define(GROUP, osiris).

register() ->
    ok = prometheus_registry:register_collector(?MODULE).

deregister_cleanup(_) ->
    ok.

collect_mf(_Registry, Callback) ->
    maps:foreach(
      fun(Name, #{type := Type,
                  help := Help,
                  values := Values}) ->
              MetricsFamily = prometheus_model_helpers:create_mf(
                                ?METRIC_NAME(Name), Help, Type, Values),
              Callback(MetricsFamily)
      end,
      histograms()).

histograms() ->
    try
        seshat_histogram:format(?GROUP)
    catch
        error:badarg ->
            %% the osiris application has not registered its metrics group
            #{}
    end.
