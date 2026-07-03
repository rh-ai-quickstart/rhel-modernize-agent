BASE_VERSION := 0.0.1
DEV_VERSION := $(BASE_VERSION)-dev
GIT_BRANCH := $(shell git symbolic-ref --short HEAD 2>/dev/null || git rev-parse HEAD 2>/dev/null || echo "")
ifeq ($(origin VERSION),undefined)
  ifeq ($(GIT_BRANCH),main)
    VERSION := $(BASE_VERSION)
  else
    VERSION := $(DEV_VERSION)
  endif
endif

CONTAINER_TOOL ?= podman
REGISTRY ?=
ARCH ?= linux/amd64
NAMESPACE ?=

# Pull policy: --policy=always for podman (pull newest); empty for docker (always pulls by default)
PULL_POLICY := $(if $(filter podman,$(CONTAINER_TOOL)),--policy=always,)

CODE_GEN_IMG ?= $(REGISTRY)/agent-mesh-for-sw-modernization-code-generation:$(VERSION)
DATA_GEN_IMG ?= $(REGISTRY)/agent-mesh-for-sw-modernization-data-generation:$(VERSION)
DATA_IDX_IMG ?= $(REGISTRY)/agent-mesh-for-sw-modernization-data-indexing:$(VERSION)

define build_image
	@echo "Building $(2)"
	$(CONTAINER_TOOL) build -t $(1) --platform=$(ARCH) -f $(3) $(4)
	@echo "Successfully built $(1)"
endef

define push_image
	@echo "Pushing $(2): $(1)"
	$(CONTAINER_TOOL) push $(1)
	@echo "Successfully pushed $(2)"
endef

##@ Image Build

build-all-images: build-code-gen-image build-data-gen-image build-data-idx-image

build-code-gen-image:
	$(call build_image,$(CODE_GEN_IMG),code-generation image,resources/code-generation/Containerfile,resources/code-generation)

build-data-gen-image:
	$(call build_image,$(DATA_GEN_IMG),data-generation image,resources/data-generation/Containerfile,resources/data-generation)

build-data-idx-image:
	$(call build_image,$(DATA_IDX_IMG),data-indexing image,resources/data-indexing/Containerfile,resources/data-indexing)

##@ Image Push

push-all-images: push-code-gen-image push-data-gen-image push-data-idx-image

push-code-gen-image:
	$(call push_image,$(CODE_GEN_IMG),code-generation image)

push-data-gen-image:
	$(call push_image,$(DATA_GEN_IMG),data-generation image)

push-data-idx-image:
	$(call push_image,$(DATA_IDX_IMG),data-indexing image)

##@ Notebooks

clean-notebooks:
	uv run --with nbstripout nbstripout workflows/code_understanding/*.ipynb
	uv run --with nbformat python -c "\
import nbformat, sys;\
[nbformat.write(nb := nbformat.read(p, as_version=4), p) for p in sys.argv[1:]]\
" workflows/code_understanding/*.ipynb

##@ Pipeline

AGENT_MESH_REPO_URL ?= $(shell git remote get-url origin 2>/dev/null)
AGENT_MESH_REPO_REF ?= $(or $(GIT_BRANCH),main)
GITHUB_TARGET_REPO         ?=
GITHUB_TARGET_BRANCH       ?= main
GIT_USERNAME               ?=
GIT_TOKEN                  ?=
NO_DELETE           ?= 0
PIPELINE_SERVER_URL = $(shell oc get route -n $(NAMESPACE) -l app=ds-pipeline-dspa \
                           -o jsonpath='https://{.items[0].spec.host}' 2>/dev/null)
RUN_ID              := $(shell date +%Y%m%d%H%M%S)
PVC_NAME            := code-understanding-pipeline-$(RUN_ID)
INDEXES_DIR         := indexes
REPO_NAME           := $(basename $(notdir $(GITHUB_TARGET_REPO)))
INDEX_TAR           ?= $(INDEXES_DIR)/graphrag-index-$(if $(REPO_NAME),$(REPO_NAME)-,)$(RUN_ID).tar.gz
CHUNK_SIZE          ?=
CHUNK_OVERLAP       ?=
LANGUAGES           ?=
MAX_CONCURRENCY     ?=
N_COMPLETIONS       ?=
QUESTION            ?=
COMMUNITY_LEVEL     ?=
INDEX_BASENAME      := $(basename $(basename $(notdir $(INDEX_TAR))))
REPORTS_DIR         := reports/$(if $(INDEX_BASENAME),$(INDEX_BASENAME),latest)
MOUNT_PATH          := /opt/app-root/src
WORKDIR             := $(MOUNT_PATH)/workflows/code_understanding
# Image used by the analysis pipeline's git_clone_step — extracted from compiled YAML so REGISTRY
# does not need to be set at run time.
_GIT_CLONE_IMAGE    := $(shell python3 -c \
    "import yaml; docs=list(yaml.safe_load_all(open('helm/files/code_analysis_pipeline.yaml'))); \
     execs={k:v for d in docs for k,v in d.get('deploymentSpec',{}).get('executors',{}).items()}; \
     print(execs.get('exec-git-clone-step',{}).get('container',{}).get('image',''))" 2>/dev/null)

define create_pvc
	@echo '{"apiVersion":"v1","kind":"PersistentVolumeClaim","metadata":{"name":"$(1)","namespace":"$(NAMESPACE)"},"spec":{"accessModes":["ReadWriteOnce"],"resources":{"requests":{"storage":"50Gi"}}}}' \
		| oc apply -n $(NAMESPACE) -f -
endef

define delete_pvc_unless_kept
	@if [ "$(NO_DELETE)" != "1" ]; then \
		oc delete pvc $(1) -n $(NAMESPACE) --ignore-not-found --wait=false; \
		echo "PVC $(1) deletion requested"; \
	else \
		echo "NO_DELETE=1 — PVC $(1) retained"; \
	fi
endef

update-pipelines: ## Compile both pipelines directly to helm/files/ and stage for commit
	DATA_GEN_IMG=$(DATA_GEN_IMG) DATA_IDX_IMG=$(DATA_IDX_IMG) \
		uv run --with kfp --with kfp-kubernetes python workflows/code_understanding/pipelines/code_understanding_pipeline.py
	DATA_IDX_IMG=$(DATA_IDX_IMG) \
		uv run --with kfp --with kfp-kubernetes python workflows/code_understanding/pipelines/code_analysis_pipeline.py
	@echo "Pipelines compiled — review and commit helm/files/*.yaml"


index-repo: ## Run indexing pipeline: make index-repo NAMESPACE=x GITHUB_TARGET_REPO=https://...
	@test -n "$(GITHUB_TARGET_REPO)" || (echo "ERROR: GITHUB_TARGET_REPO is required"; exit 1)
	@test -n "$(PIPELINE_SERVER_URL)" || \
		(echo "ERROR: could not derive PIPELINE_SERVER_URL — check oc login and NAMESPACE"; exit 1)
	$(call create_pvc,$(PVC_NAME))
	OC_TOKEN=$$(oc whoami -t) \
	uv run --with kfp python3 -c "\
import os, urllib3; urllib3.disable_warnings(urllib3.exceptions.InsecureRequestWarning); \
from kfp.client import Client; \
c = Client(host='$(PIPELINE_SERVER_URL)', existing_token=os.environ['OC_TOKEN'], verify_ssl=False); \
args = {'pvc_name': '$(PVC_NAME)', 'repo_url': '$(AGENT_MESH_REPO_URL)', \
        'repo_ref': '$(AGENT_MESH_REPO_REF)', 'git_repo': '$(GITHUB_TARGET_REPO)', \
        'git_branch': '$(GITHUB_TARGET_BRANCH)'}; \
$(if $(CHUNK_SIZE),args.update({'chunk_size': $(CHUNK_SIZE)});) \
$(if $(CHUNK_OVERLAP),args.update({'chunk_overlap': $(CHUNK_OVERLAP)});) \
$(if $(LANGUAGES),args.update({'languages': '$(LANGUAGES)'});) \
$(if $(MAX_CONCURRENCY),args.update({'max_concurrency': $(MAX_CONCURRENCY)});) \
$(if $(N_COMPLETIONS),args.update({'n_completions': $(N_COMPLETIONS)});) \
run = c.create_run_from_pipeline_package('helm/files/code_understanding_pipeline.yaml', \
    arguments=args); \
print(f'Run submitted: {run.run_id}'); \
result = c.wait_for_run_completion(run.run_id, timeout=7200); \
print(f'Run completed: {result.state}'); \
exit(0 if str(result.state) == 'SUCCEEDED' else 1)"
	oc run index-downloader-$(RUN_ID) -n $(NAMESPACE) --image=registry.access.redhat.com/ubi9 --restart=Never \
		--overrides='{"spec":{"serviceAccountName":"pipeline-runner-dspa","volumes":[{"name":"pvc","persistentVolumeClaim":{"claimName":"$(PVC_NAME)"}}],"containers":[{"name":"dl","image":"registry.access.redhat.com/ubi9","command":["sleep","infinity"],"volumeMounts":[{"mountPath":"$(MOUNT_PATH)","name":"pvc"}]}]}}'
	oc wait --for=condition=Ready pod/index-downloader-$(RUN_ID) -n $(NAMESPACE) --timeout=300s
	mkdir -p $(INDEXES_DIR)
	oc cp $(NAMESPACE)/index-downloader-$(RUN_ID):$(WORKDIR)/graphrag-index.tar.gz ./$(INDEX_TAR)
	oc delete pod index-downloader-$(RUN_ID) -n $(NAMESPACE)
	@echo "Index downloaded to $(INDEX_TAR)"
	$(call delete_pvc_unless_kept,$(PVC_NAME))

run-analysis: ## Run analysis pipeline: make run-analysis NAMESPACE=x INDEX_TAR=indexes/graphrag-index-<repo>-YYYYMMDDHHMMSS.tar.gz
	@test -f "$(INDEX_TAR)" || \
		(echo "ERROR: $(INDEX_TAR) not found — pass the tar from a previous index-repo run: make run-analysis INDEX_TAR=indexes/graphrag-index-<repo>-YYYYMMDDHHMMSS.tar.gz"; exit 1)
	@test -n "$(PIPELINE_SERVER_URL)" || \
		(echo "ERROR: could not derive PIPELINE_SERVER_URL — check oc login and NAMESPACE"; exit 1)
	@test -n "$(_GIT_CLONE_IMAGE)" || \
		(echo "ERROR: could not extract git-clone-step image from helm/files/code_analysis_pipeline.yaml — run 'make update-pipelines' first"; exit 1)
	$(call create_pvc,$(PVC_NAME))
	# Start a long-lived pod using the same image as the pipeline's git_clone_step.
	# It sleeps until the pipeline's git_clone_step has created the working directory,
	# at which point we upload the index tar into that directory and delete the pod.
	oc run analysis-uploader-$(RUN_ID) -n $(NAMESPACE) --image=$(_GIT_CLONE_IMAGE) --restart=Never \
		--overrides='{"spec":{"serviceAccountName":"pipeline-runner-dspa","volumes":[{"name":"pvc","persistentVolumeClaim":{"claimName":"$(PVC_NAME)"}}],"containers":[{"name":"ul","image":"$(_GIT_CLONE_IMAGE)","command":["sleep","infinity"],"volumeMounts":[{"mountPath":"$(MOUNT_PATH)","name":"pvc"}]}]}}'
	oc wait --for=condition=Ready pod/analysis-uploader-$(RUN_ID) -n $(NAMESPACE) --timeout=300s
	$(if $(QUESTION),$(file >/tmp/pipeline_question_$(RUN_ID).txt,$(QUESTION)))
	# Step 1: submit the pipeline and save the run ID for later.
	OC_TOKEN=$$(oc whoami -t) \
	uv run --with kfp python3 -c "\
import os, urllib3; urllib3.disable_warnings(urllib3.exceptions.InsecureRequestWarning); \
from kfp.client import Client; \
c = Client(host='$(PIPELINE_SERVER_URL)', existing_token=os.environ['OC_TOKEN'], verify_ssl=False); \
args = {'pvc_name': '$(PVC_NAME)', 'repo_url': '$(AGENT_MESH_REPO_URL)', \
        'repo_ref': '$(AGENT_MESH_REPO_REF)', 'index_tar': 'graphrag-index.tar.gz'}; \
$(if $(QUESTION),args.update({'question': open('/tmp/pipeline_question_$(RUN_ID).txt').read()});) \
$(if $(COMMUNITY_LEVEL),args.update({'community_level': $(COMMUNITY_LEVEL)});) \
run = c.create_run_from_pipeline_package('helm/files/code_analysis_pipeline.yaml', \
    arguments=args); \
print(f'Run submitted: {run.run_id}'); \
open('/tmp/kfp_run_id_$(RUN_ID).txt', 'w').write(run.run_id)"
	# Step 2: poll until git_clone_step has created the working directory on the PVC.
	@echo "Waiting for git_clone_step to create $(WORKDIR) on PVC..."
	@until oc exec analysis-uploader-$(RUN_ID) -n $(NAMESPACE) -- \
		test -d $(WORKDIR) 2>/dev/null; do printf '.'; sleep 5; done; echo " ready"
	# Step 3: upload the index tar into the now-existing directory, then clean up the pod.
	oc cp $(INDEX_TAR) $(NAMESPACE)/analysis-uploader-$(RUN_ID):$(WORKDIR)/graphrag-index.tar.gz
	oc delete pod analysis-uploader-$(RUN_ID) -n $(NAMESPACE)
	@echo "Upload complete — waiting for pipeline to finish..."
	# Step 4: wait for the full pipeline to complete.
	OC_TOKEN=$$(oc whoami -t) \
	uv run --with kfp python3 -c "\
import os, urllib3; urllib3.disable_warnings(urllib3.exceptions.InsecureRequestWarning); \
from kfp.client import Client; \
c = Client(host='$(PIPELINE_SERVER_URL)', existing_token=os.environ['OC_TOKEN'], verify_ssl=False); \
run_id = open('/tmp/kfp_run_id_$(RUN_ID).txt').read().strip(); \
result = c.wait_for_run_completion(run_id, timeout=3600); \
print(f'Run completed: {result.state}'); \
exit(0 if str(result.state) == 'SUCCEEDED' else 1)"
	mkdir -p $(REPORTS_DIR)
	oc run analysis-downloader-$(RUN_ID) -n $(NAMESPACE) --image=registry.access.redhat.com/ubi9 --restart=Never \
		--overrides='{"spec":{"serviceAccountName":"pipeline-runner-dspa","volumes":[{"name":"pvc","persistentVolumeClaim":{"claimName":"$(PVC_NAME)"}}],"containers":[{"name":"dl","image":"registry.access.redhat.com/ubi9","command":["sleep","infinity"],"volumeMounts":[{"mountPath":"$(MOUNT_PATH)","name":"pvc"}]}]}}'
	oc wait --for=condition=Ready pod/analysis-downloader-$(RUN_ID) -n $(NAMESPACE) --timeout=300s
	oc exec analysis-downloader-$(RUN_ID) -n $(NAMESPACE) -- tar cf - -C $(WORKDIR)/reports . | tar xf - -C ./$(REPORTS_DIR)/
	oc delete pod analysis-downloader-$(RUN_ID) -n $(NAMESPACE)
	@echo "Reports downloaded to ./$(REPORTS_DIR)/"
	$(call delete_pvc_unless_kept,$(PVC_NAME))

##@ Deployment

install:
	@test -f helm/files/code_understanding_pipeline.yaml || \
		(echo "ERROR: helm/files/code_understanding_pipeline.yaml not found. Run 'make update-pipelines' first."; exit 1)
	@test -f helm/files/code_analysis_pipeline.yaml || \
		(echo "ERROR: helm/files/code_analysis_pipeline.yaml not found. Run 'make update-pipelines' first."; exit 1)
	oc new-project $(NAMESPACE) 2>/dev/null || oc project $(NAMESPACE)
	oc label namespace $(NAMESPACE) opendatahub.io/dashboard=true --overwrite
	oc create secret generic code-understanding-env --from-env-file=.env -n $(NAMESPACE) 2>/dev/null || \
		oc create secret generic code-understanding-env --from-env-file=.env -n $(NAMESPACE) --dry-run=client -o yaml | oc apply -f -
	oc create secret generic git-credentials \
		--from-literal=GIT_USERNAME='$(GIT_USERNAME)' \
		--from-literal=GIT_TOKEN='$(GIT_TOKEN)' \
		-n $(NAMESPACE) 2>/dev/null || \
		oc create secret generic git-credentials \
		--from-literal=GIT_USERNAME='$(GIT_USERNAME)' \
		--from-literal=GIT_TOKEN='$(GIT_TOKEN)' \
		-n $(NAMESPACE) --dry-run=client -o yaml | oc apply -f -
	helm upgrade --install code-understanding ./helm \
		--namespace $(NAMESPACE) \
		--set registry=$(REGISTRY) \
		--set version=$(VERSION) \
		--set namespace=$(NAMESPACE) \
		--set repoUrl='$(AGENT_MESH_REPO_URL)' \
		--set repoRef=$(or $(GIT_BRANCH),main)

uninstall:
	helm uninstall code-understanding --namespace $(NAMESPACE) 2>/dev/null || true
	oc delete job minio-init register-pipelines -n $(NAMESPACE) --ignore-not-found
	oc delete pvc workbench-data-generation-pvc workbench-data-indexing-pvc minio-pvc -n $(NAMESPACE) --ignore-not-found
	oc delete secret git-credentials code-understanding-env -n $(NAMESPACE) --ignore-not-found
	oc delete workflow --all -n $(NAMESPACE) 2>/dev/null || true
	oc get pod -n $(NAMESPACE) -o name 2>/dev/null | grep -E 'index-downloader-|analysis-uploader-|analysis-downloader-' | xargs -r oc delete -n $(NAMESPACE) --ignore-not-found
	oc get pvc -n $(NAMESPACE) -o name 2>/dev/null | grep code-understanding-pipeline | xargs -r oc delete -n $(NAMESPACE) --wait=false
