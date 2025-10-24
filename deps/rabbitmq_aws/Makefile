PROJECT = rabbitmq_aws
PROJECT_DESCRIPTION = AWS API library used by rabbitmq_peer_discovery_aws
PROJECT_MOD = rabbitmq_aws_app
PROJECT_REGISTERED = rabbitmq_aws_sup

define PROJECT_ENV
[]
endef

DEPS = gun
BUILD_DEPS = rabbit_common rabbit
TEST_DEPS = meck
LOCAL_DEPS = crypto inets ssl xmerl public_key

PLT_APPS = rabbit

DEP_EARLY_PLUGINS = rabbit_common/mk/rabbitmq-early-plugin.mk
DEP_PLUGINS = rabbit_common/mk/rabbitmq-plugin.mk

include ../../rabbitmq-components.mk
include ../../erlang.mk
