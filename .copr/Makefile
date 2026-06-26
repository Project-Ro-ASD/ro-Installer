spec ?= ro-installer.spec
outdir ?= $(CURDIR)

.PHONY: srpm

srpm:
	@test -f "$(spec)" || { echo "Spec file not found: $(spec)"; exit 1; }
	@mkdir -p "$(outdir)"
	@name=$$(rpmspec -q --srpm --qf '%{name}\n' "$(spec)" 2>/dev/null | head -n1 || true); \
	version=$$(rpmspec -q --srpm --qf '%{version}\n' "$(spec)" 2>/dev/null | head -n1 || true); \
	if [ -z "$$name" ] || echo "$$name" | grep -q '%'; then \
	  name=$$(sed -n 's/^Name:[[:space:]]*//p' "$(spec)" | head -n1); \
	fi; \
	if [ -z "$$version" ] || echo "$$version" | grep -q '%'; then \
	  pub_version=$$(awk '/^version:/ {print $$2; exit}' pubspec.yaml); \
	  version=$${pub_version%%+*}; \
	fi; \
	test -n "$$name" && test -n "$$version" || { echo "Unable to parse Name/Version from $(spec)"; exit 1; }; \
	tarball="$(outdir)/$$name-$$version.tar.gz"; \
	staging="$(outdir)/.copr-srpm-tmp"; \
		rm -rf "$$staging"; \
		echo "Generating $$tarball from checked out sources"; \
		if git rev-parse --is-inside-work-tree >/dev/null 2>&1 && git rev-parse --verify HEAD >/dev/null 2>&1; then \
		  git archive --worktree-attributes --format=tar --prefix="$$name-$$version/" HEAD | gzip -cn > "$$tarball"; \
		else \
		  mkdir -p "$$staging/$$name-$$version"; \
		  rsync -a --delete \
		    --exclude ".git" \
		    --exclude ".git/" \
		    --exclude ".idea" \
		    --exclude ".idea/" \
		    --exclude ".codex" \
		    --exclude ".codex/" \
		    --exclude ".agents" \
		    --exclude ".agents/" \
		    --exclude ".dart_tool" \
		    --exclude ".dart_tool/" \
		    --exclude ".pub-cache" \
		    --exclude ".pub-cache/" \
		    --exclude ".pub" \
		    --exclude ".pub/" \
		    --exclude "build" \
		    --exclude "build/" \
		    --exclude "coverage" \
		    --exclude "coverage/" \
		    --exclude "COPR.md" \
		    --exclude "docs/old" \
		    --exclude "docs/old/" \
		    --exclude "docs/road.md" \
		    --exclude "docs/road-plan.md" \
		    --exclude "docs/git-yukleme-notu.md" \
		    --exclude "docs/grafik-driver-politikasi.md" \
		    --exclude "docs/profesyonel-installer-ana-plani.md" \
		    --exclude "docs/ro-apps-packaging-notu.md" \
		    --exclude "docs/siyah-ekran-kernel-notlari.md" \
		    --exclude "docs/sonraki-adim-notu.md" \
		    --exclude "docs/yeni-makine-qemu-rehberi.md" \
		    --exclude "durum.md" \
		    --exclude "eksikler.md" \
		    --exclude "gerçeksistemdenloglar" \
		    --exclude "gerçeksistemdenloglar/" \
		    --exclude "implementation_plan.md" \
		    --exclude "kernel-black-screen-diagnostics.md" \
		    --exclude "optimizasyon.md" \
		    --exclude "plan.md" \
		    --exclude "test.md" \
		    --exclude "outputs" \
		    --exclude "outputs/" \
		    --exclude "rpm-outputs" \
		    --exclude "rpm-outputs/" \
		    --exclude "iso-release" \
		    --exclude "iso-release/" \
		    --exclude "iso-realese" \
		    --exclude "iso-realese/" \
		    --exclude "linux/flutter/ephemeral" \
		    --exclude "linux/flutter/ephemeral/" \
		    --exclude "__pycache__" \
		    --exclude "__pycache__/" \
		    --exclude ".copr-srpm-tmp" \
		    --exclude ".copr-srpm-tmp/" \
		    --exclude "*.iso" \
		    --exclude "*.qcow2" \
		    --exclude "*.fd" \
		    --exclude "*.rpm" \
		    --exclude "*.src.rpm" \
		    --exclude "*.tar.gz" \
		    --exclude "*.pyc" \
		    --exclude "*.log" \
		    --exclude ".git.broken-*" \
		    --exclude ".git.broken-*/" \
		    --exclude "stitch_velvet_nebula_installer_redesign" \
		    --exclude "stitch_velvet_nebula_installer_redesign/" \
		    ./ "$$staging/$$name-$$version/"; \
		  tar --sort=name --mtime='UTC 1970-01-01' --owner=0 --group=0 --numeric-owner -C "$$staging" -czf "$$tarball" "$$name-$$version"; \
		  rm -rf "$$staging"; \
		fi; \
		bad=$$(tar -tzf "$$tarball" | grep -E '(^|/)(\.git|\.idea|\.codex|\.agents|\.dart_tool|build|coverage|docs/old|gerçeksistemdenloglar|outputs|rpm-outputs|iso-release|iso-realese|linux/flutter/ephemeral|__pycache__)(/|$$)|(^|/)(COPR|durum|eksikler|implementation_plan|kernel-black-screen-diagnostics|optimizasyon|plan|test)\.md$$|(^|/)docs/(road|road-plan|git-yukleme-notu|grafik-driver-politikasi|profesyonel-installer-ana-plani|ro-apps-packaging-notu|siyah-ekran-kernel-notlari|sonraki-adim-notu|yeni-makine-qemu-rehberi)\.md$$|\.(iso|qcow2|fd|rpm|src\.rpm|tar\.gz|pyc|log)$$' | head -n 50 || true); \
		if [ -n "$$bad" ]; then \
		  echo "Source tarball contains forbidden files:"; \
		  echo "$$bad"; \
		  exit 1; \
		fi; \
		sha256sum "$$tarball" > "$$tarball.sha256"; \
		echo "Building SRPM into $(outdir)"; \
	rpmbuild -bs "$(spec)" \
	  --define "_sourcedir $(outdir)" \
	  --define "_srcrpmdir $(outdir)"
