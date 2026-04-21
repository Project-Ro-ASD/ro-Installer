spec ?= ro-installer.spec
outdir ?= $(CURDIR)

.PHONY: srpm

srpm:
	@test -f "$(spec)" || { echo "Spec file not found: $(spec)"; exit 1; }
	@mkdir -p "$(outdir)"
	@name=$$(sed -n 's/^Name:[[:space:]]*//p' "$(spec)" | head -n1); \
	version=$$(sed -n 's/^Version:[[:space:]]*//p' "$(spec)" | head -n1); \
	test -n "$$name" && test -n "$$version" || { echo "Unable to parse Name/Version from $(spec)"; exit 1; }; \
	tarball="$(outdir)/$$name-$$version.tar.gz"; \
	staging="$(outdir)/.copr-srpm-tmp"; \
	rm -rf "$$staging"; \
	mkdir -p "$$staging/$$name-$$version"; \
	echo "Generating $$tarball from checked out sources"; \
	cp -a . "$$staging/$$name-$$version/"; \
	rm -rf "$$staging/$$name-$$version/.git" \
	       "$$staging/$$name-$$version/dist" \
	       "$$staging/$$name-$$version/build" \
	       "$$staging/$$name-$$version/outputs" \
	       "$$staging/$$name-$$version/linux/__pycache__"; \
	tar -C "$$staging" -czf "$$tarball" "$$name-$$version"; \
	rm -rf "$$staging"; \
	echo "Building SRPM into $(outdir)"; \
	rpmbuild -bs "$(spec)" \
	  --define "_sourcedir $(outdir)" \
	  --define "_srcrpmdir $(outdir)"
