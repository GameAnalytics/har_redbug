.PHONY: all

all:
	rebar3 compile
	rebar3 escriptize
	@echo "Done! Your executable is in _build/default/bin/har_redbug"
