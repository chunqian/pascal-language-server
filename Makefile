
.PHONY: build clear write build-all clear-all write-all

define build-pkg
	@cd $(1) && make
endef

define clear-pkg
	@cd $(1) && make clean
endef

define build-project
	@cd $(1) && make
endef

define clear-project
	@cd $(1) && make cleardist
endef

define write-project
	@cd $(1) && fpcmake -w
endef

build-all: \
	build-pkg \
	build-proxy \
	build-sock \
	build-pasls

clear-all: \
	clear-pkg \
	clear-proxy \
	clear-sock \
	clear-pasls

write-all: \
	write-proxy \
	write-sock \
	write-pasls

# ******************** pkg ********************
build-pkg:
	$(call build-pkg, .pkg/packager/registration)
	$(call build-pkg, .pkg/components/lazutils)
	$(call build-pkg, .pkg/components/codetools)

clear-pkg:
	$(call clear-pkg, .pkg/packager/registration)
	$(call clear-pkg, .pkg/components/lazutils)
	$(call clear-pkg, .pkg/components/codetools)

# ******************** proxy ********************
build-proxy:
	$(call build-project, src/proxy)

clear-proxy:
	$(call clear-project, src/proxy)

write-proxy:
	$(call write-project, src/proxy)

# ******************** sock ********************
build-sock:
	$(call build-project, src/socketserver)

clear-sock:
	$(call clear-project, src/socketserver)

write-sock:
	$(call write-project, src/socketserver)

# ******************** pasls ********************
build-pasls:
	$(call build-project, src/standard)

clear-pasls:
	$(call clear-project, src/standard)

write-pasls:
	$(call write-project, src/standard)
