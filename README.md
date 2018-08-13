har_redbug
=====

Attach to an Erlang node, trace both incoming and outgoing HTTP
requests, and write a file in [HAR format][har-format].

HAR files can be viewed in popular web browsers: open developer tools,
select the "Network" tab, and drag and drop the HAR file into the
window.  You can also use the [HTTP Archive Viewer Chrome
extension][har-viewer].

As the name implies, this tool is based on [redbug][redbug].

Currently supported:

* cowboy (incoming requests)
* shotgun (outgoing requests)

[har-format]: http://www.softwareishard.com/blog/har-12-spec/
[har-viewer]: https://chrome.google.com/webstore/detail/http-archive-viewer/ebbdbdmhegaoooipfnjikefdpeoaidml
[redbug]: https://github.com/massemanet/redbug

Build
-----

    $ rebar3 compile && rebar3 escriptize

Run
---

    $ _build/default/bin/har_redbug NODENAME -cookie COOKIE -msgs 1000 -time 15000

That is, connect to NODENAME with the given cookie, and collect data
until 1000 trace messages have been received or 15 seconds have
passed, whichever comes first.

The output is written to `redbug.har` in the current directory.
