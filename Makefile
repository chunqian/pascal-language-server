
.PHONY: build clear write build-all clear-all write-all

define build-project
	@cd $(1) && make
endef

define clear-project
	@cd $(1) && make cleardist
endef

define write-project
	@cd $(1) && fpcmake -w
endef

define run-project
	@cd $(1) && $(2)
endef

build-all: \
	build-proxy \
	build-sock \
	build-pasls

clear-all: \
	clear-proxy \
	clear-sock \
	clear-pasls

write-all: \
	write-proxy \
	write-sock \
	write-pasls

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
