-module(diam_app).

-behaviour(application).

-export([start/2,
         stop/1
        ]).

-spec start(_, _) -> {ok, pid()}.
start(_, _) ->
  diam_sup:start_link().

-spec stop(_) -> ok.
stop(_) ->
  ok.
