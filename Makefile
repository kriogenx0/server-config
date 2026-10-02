# Deploys every "simple site" tracked directly in this repo, i.e. the ones
# under www/<domain>/ (see docs/AGENTS.md "Simple Sites"). Apps with their
# own repo keep their own deploy.sh and their own `make deploy` instead --
# e.g. tandavacult.com, in ~/Sites/tandava.
#
# Installing a site's sudoers.d rule needs admin's interactive sudo
# password -- deploy has no sudo to install its own rule, only admin does
# (see any www/*/deploy/deploy.sh header). This re-runs that install every
# time: harmless, since visudo -c + install just rewrite the same file.
# Each site's own deploy.sh is likewise safe to re-run.
ADMIN_TARGET := admin@104.131.183.186
SUDOERS_FILES := $(wildcard www/*/deploy/sudoers.d/*)
SUDOERS_NAMES := $(notdir $(SUDOERS_FILES))
DEPLOY_SCRIPTS := $(wildcard www/*/deploy/deploy.sh)

.PHONY: deploy-sites install-sudoers

deploy-sites: install-sudoers
	@for script in $(DEPLOY_SCRIPTS); do \
		echo "==> Running $$script"; \
		"$$script" || exit 1; \
	done

install-sudoers:
ifeq ($(strip $(SUDOERS_FILES)),)
	@echo "No sudoers rules to install."
else
	@echo "==> Copying sudoers rules to $(ADMIN_TARGET):/tmp/"
	scp $(SUDOERS_FILES) $(ADMIN_TARGET):/tmp/
	@echo "==> Installing them as root (needs your admin password)"
	ssh -t $(ADMIN_TARGET) 'for f in $(SUDOERS_NAMES); do sudo visudo -c -f /tmp/$$f && sudo install -m 0440 -o root -g root /tmp/$$f /etc/sudoers.d/$$f && rm /tmp/$$f; done'
endif
