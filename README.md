
Testing
---

Open two Erlang shells and run

    A@1> diam:start_server().

    B@1> diam:start_client().


How does it work
---

There are a state machine for the diameter-peer application 0 messages
(`diam_peer`), and one state machine for the sctp socket handling
(`diam_sctp`). There is also a gen-server (`diam_sctp_child`) for
which takes over the socket handling as soon as the socket has been
connected.


