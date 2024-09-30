default: writing

writing: writing/process-aware-types.html

.SILENT:
writing/process-aware-types.html: writing/process-aware-types.md
	pandoc \
		--standalone \
		--number-sections \
		-f markdown \
		-t html5 \
		--highlight-style haddock \
		-o $@ \
		$^
