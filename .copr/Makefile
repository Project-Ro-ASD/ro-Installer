NAME=ro-installer
VERSION=1.0.0
# COPR's default SRPM output directory and temporary variables
OUTDIR ?= .

.PHONY: srpm tarball

# 1. Create the source tarball exactly as the spec expects it
tarball:
	@echo ">>> Creating tarball using git archive..."
	git archive --format=tar.gz --prefix=$(NAME)-$(VERSION)/ HEAD -o $(NAME)-$(VERSION).tar.gz

# 2. Build the Source RPM (SRPM)
srpm: tarball
	@echo ">>> Building SRPM for COPR..."
	mkdir -p rpmbuild/{BUILD,RPMS,SOURCES,SPECS,SRPMS}
	cp ro-installer.spec rpmbuild/SPECS/
	mv $(NAME)-$(VERSION).tar.gz rpmbuild/SOURCES/
	
	# Define topdir for local building within the container
	rpmbuild -bs --nodeps --define "_topdir $$(pwd)/rpmbuild" rpmbuild/SPECS/ro-installer.spec
	
	# Move the resulting SRPM to the expected output directory
	cp rpmbuild/SRPMS/*.src.rpm $(OUTDIR)/
	
	# Cleanup
	rm -rf rpmbuild
