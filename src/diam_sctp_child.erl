-module(diam_sctp_child).
-moduledoc """
  Socket controlling process when SCTP-statem is in open.
  Tight send/receive on socket.
""".

-behaviour(gen_server).

-export([start_link/2,
         give_control/2,
         send_msg/2
        ]).

-export([init/1,
         handle_call/3,
         handle_cast/2,
         handle_info/2,
         terminate/2
        ]).

-define(LOOP_TIMEOUT, timer:seconds(1)).

%% ---------------------------------------------------------------------------
%% API
%% ---------------------------------------------------------------------------

start_link(Socket, Parent) ->
  gen_server:start_link({local, ?MODULE}, ?MODULE, [Socket, Parent], []).

give_control(Child, Socket) ->
  ok = socket:setopt(Socket, {otp, controlling_process}, Child),
  gen_server:cast(Child, good_to_go).

send_msg(Child, Msg) ->
  gen_server:cast(Child, {send_msg, Msg}).

%% ---------------------------------------------------------------------------
%% Gen Server
%% ---------------------------------------------------------------------------

init([Socket, Parent]) ->
  State = #{
    socket => Socket,
    parent => Parent
    },
  {ok, State}.

handle_call(_, _, State) ->
  {stop, call, State}.

handle_cast(good_to_go, State) ->
  io:format("~p:~p:~p~n", [?MODULE, good_to_go, ?LINE]),
  NewState = start_timeout(State),
  {noreply, NewState};
handle_cast({send_msg, Msg}, #{socket := Socket} = State) ->
  io:format("~p:~p:~p~n", [?MODULE, send_msg, ?LINE]),
  send_msgs(Socket, [Msg]),
  {noreply, State}.

handle_info(stop, #{socket := Socket, parent := Parent} = State) ->
  ok = socket:setopt(Socket, {otp, controlling_process}, Parent),
  {stop, parent, State};
handle_info({timeout, receive_loop}, #{socket := Socket, parent := Parent} = State) ->
  io:format("~p:~p:~p~n", [?MODULE, timeout, ?LINE]),
  receive_msgs(Socket, Parent),
  NewState = start_timeout(State),
  {noreply, NewState}.

terminate(_Reason, _State) ->
  ok.

%% ---------------------------------------------------------------------------
%% Help functions
%% ---------------------------------------------------------------------------

start_timeout(State) ->
  {ok, TRef} = timer:send_after(?LOOP_TIMEOUT, {timeout, receive_loop}),
  State#{timer => TRef}.

receive_msgs(Socket, Parent) ->
  receive_msgs(Socket, Parent, 10).

receive_msgs(_Socket, _Parent, 0) ->
  ok;
receive_msgs(Socket, Parent, Max) ->
  Ref = make_ref(),
  case socket:recvmsg(Socket, 0, 0, [], Ref) of
    {ok, Msg} ->
      io:format("~p:~p:~p ~p~n", [?MODULE, socket, ?LINE, Msg]),
      diam_sctp:receive_msg(Parent, Msg),
      receive_msgs(Socket, Parent, Max-1);
    {select, SelectInfo} ->
      socket:cancel(Socket, SelectInfo);
    {error, closed} ->
      ok = socket:shutdown(Socket, read),
      diam_sctp:control_msg(Parent, closed),
      ok;
    {error, Err} ->
      io:format("~p:~p:~p (~p)~n", [?MODULE, ?FUNCTION_NAME, ?LINE, Err]),
      receive_msgs(Socket, Parent, Max-1)
  end.

send_msgs(_Socket, []) ->
  ok;
send_msgs(Socket, {Iov, SelectInfo}) ->
  Ref = make_ref(),
  case socket:sendmsg(Socket, Iov, SelectInfo, Ref) of
    ok ->
      ok;
    {select, {SelectInfo2, RestData2}} ->
      send_msgs(Socket, {RestData2, SelectInfo2});
    {select, SelectInfo2} ->
      ok = socket:cancel(Socket, SelectInfo2);
    {error, {Err, RestData}} ->
      io:format("~p:~p:~p (~p, ~p)~n", [?MODULE, ?FUNCTION_NAME, ?LINE, Err, RestData]),
      ok;
    {error, Err} ->
      io:format("~p:~p:~p (~p)~n", [?MODULE, ?FUNCTION_NAME, ?LINE, Err]),
      ok
  end;
send_msgs(Socket, Msgs) ->
  send_msgs(Socket, {#{iov => Msgs}, []}).


