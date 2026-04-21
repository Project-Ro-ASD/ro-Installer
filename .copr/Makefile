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
	echo "Generating $$tarball from git checkout"; \
	git archive --format=tar.gz --prefix="$$name-$$version/" -o "$$tarball" HEAD; \
	echo "Building SRPM into $(outdir)"; \
	rpmbuild -bs "$(spec)" \
	  --define "_sourcedir $(outdir)" \
	  --define "_srcrpmdir $(outdir)"
