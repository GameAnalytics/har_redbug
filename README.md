har_redbug
=====

Attach to an Erlang node, trace both incoming and outgoing HTTP
requests, and write a file in [HAR format][har-format].

HAR files can be viewed in popular web browsers: open developer tools,
select the "Network" tab, and drag and drop the HAR file into the
window.  You can also use the [HTTP Archive Viewer Chrome
extension][har-viewer].

The purpose of this tool is to get a transcript of HTTP requests for
development, debugging, and documentation.  It is possible to achieve
something similar by capturing network traffic using e.g. tcpdump or
Wireshark, but that doesn't work as well when connections are
encrypted.

As the name implies, this tool is based on [redbug][redbug].

Currently supported:

* cowboy 1 and 2 (incoming requests)
* shotgun (outgoing requests)
* hackney (outgoing requests)

[har-format]: http://www.softwareishard.com/blog/har-12-spec/
[har-viewer]: https://chrome.google.com/webstore/detail/http-archive-viewer/ebbdbdmhegaoooipfnjikefdpeoaidml
[redbug]: https://github.com/massemanet/redbug

Build
-----

    $ rebar3 compile && rebar3 escriptize

This generates an escript archive in `_build/default/bin/har_redbug`.
The archive is path-independent, so you can move it wherever you want.
It only contains BEAM files, so it is platform-independent: you can
run it anywhere you have `escript` in the path.

Run
---

    $ _build/default/bin/har_redbug NODENAME -cookie COOKIE -msgs 1000 -time 15000

That is, connect to NODENAME with the given cookie, and collect data
until 1000 trace messages have been received or 15 seconds have
passed, whichever comes first.

The output is written to `redbug.har` in the current directory.
