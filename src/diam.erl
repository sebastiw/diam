-module(diam).

-export([start_server/0,
         start_client/0
        ]).

start_server() ->
  Opts = #{
    transport_options => #{name => transport_server, mode => server, local_port => 3868, local_ip_addresses => ["127.0.0.1"]},
    peer_options => #{name => peer_server, mode => server, local_host => <<"peer.server.se">>, local_realm => <<"server.se">>}
    },
  diam_sctp:start_link(normalize_config(Opts)).

start_client() ->
  Opts = #{
    transport_options => #{name => transport_client, mode => client, remote_port => 3868, remote_ip_addresses => ["127.0.0.1"], local_ip_addresses => ["127.0.0.1"]},
    peer_options => #{name => peer_client, mode => client, local_host => <<"peer.client.se">>, local_realm => <<"client.se">>}
    },
  diam_sctp:start_link(normalize_config(Opts)).

normalize_config(Opts) ->
  TOpts0 = maps:get(transport_options, Opts),
  TOpts1 = maps:update_with(local_ip_addresses, fun parse_ip_addrs/1, [], TOpts0),
  TOpts2 = maps:update_with(remote_ip_addresses, fun parse_ip_addrs/1, [], TOpts1),
  Opts#{transport_options => TOpts2
    }.


parse_ip_addrs([]) ->
  [];
parse_ip_addrs([Addr|As]) ->
  {ok, I} = inet:parse_address(Addr),
  [I|parse_ip_addrs(As)].
