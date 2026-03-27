NAME=ro-installer
VERSION=1.0.0
# COPR'ın SRPM üretiminde çıktıları bıraktığı dizin OUTDIR'dır. COPR default OUTDIR=. yollar.
OUTDIR ?= .

.PHONY: srpm tarball clean

tarball:
	@echo ">>> Kaynak kodlar (tar.gz) arşivleniyor..."
	mkdir -p $(NAME)-$(VERSION)
	# rsync her ortamda yüklü olmadığı için cp ve tar kullanıyoruz
	cp -a * $(NAME)-$(VERSION)/ 2>/dev/null || true
	cp -a .[^.]* $(NAME)-$(VERSION)/ 2>/dev/null || true
	# Arşiv içindeki dev ve build klasörlerini siliyoruz
	rm -rf $(NAME)-$(VERSION)/$(NAME)-$(VERSION)
	rm -rf $(NAME)-$(VERSION)/.git
	rm -rf $(NAME)-$(VERSION)/.dart_tool
	rm -rf $(NAME)-$(VERSION)/.pub-cache
	rm -rf $(NAME)-$(VERSION)/build
	rm -f $(NAME)-$(VERSION)/*.tar.gz
	rm -f $(NAME)-$(VERSION)/*.rpm
	tar -czf $(NAME)-$(VERSION).tar.gz $(NAME)-$(VERSION)
	rm -rf $(NAME)-$(VERSION)

srpm: tarball
	@echo ">>> Geçici rpmbuild ortamı oluşturuluyor ve SRPM derleniyor..."
	mkdir -p rpmbuild/{BUILD,RPMS,SOURCES,SPECS,SRPMS}
	cp ro-installer.spec rpmbuild/SPECS/
	mv $(NAME)-$(VERSION).tar.gz rpmbuild/SOURCES/
	
	rpmbuild -bs --nodeps --define "_topdir $$(pwd)/rpmbuild" rpmbuild/SPECS/ro-installer.spec
	
	@echo ">>> Üretilen .src.rpm dosyasi $(OUTDIR) dizinine aktarılıyor..."
	mkdir -p $(OUTDIR)
	mv rpmbuild/SRPMS/*.src.rpm $(OUTDIR)/
	
	@echo ">>> Geçici ortam temizleniyor..."
	rm -rf rpmbuild

clean:
	rm -rf rpmbuild
	rm -f *.tar.gz
	rm -f *.rpm
