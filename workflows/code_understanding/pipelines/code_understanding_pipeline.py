import os
from kfp import dsl, compiler
from kfp.kubernetes import mount_pvc, use_secret_as_env

MOUNT_PATH = "/opt/app-root/src"
WORKDIR = "/opt/app-root/src/workflows/code_understanding"

DATA_GENERATION_IMAGE = os.environ.get("DATA_GEN_IMG", "")
DATA_INDEXING_IMAGE = os.environ.get("DATA_IDX_IMG", "")

GIT_SECRET_NAME = "git-credentials"
GIT_SECRET_ENV_VARS = {"GIT_USERNAME": "GIT_USERNAME", "GIT_TOKEN": "GIT_TOKEN"}

LLM_SECRET_NAME = "code-understanding-env"
LLM_ENV_VARS = {
    "GRAPHRAG_LLM_TOKEN":             "GRAPHRAG_LLM_TOKEN",
    "GRAPHRAG_LLM_ID":                "GRAPHRAG_LLM_ID",
    "GRAPHRAG_LLM_API_BASE":          "GRAPHRAG_LLM_API_BASE",
    "GRAPHRAG_LLM_PROVIDER":          "GRAPHRAG_LLM_PROVIDER",
    "GRAPHRAG_LLM_PROVIDER_GRAPHRAG": "GRAPHRAG_LLM_PROVIDER_GRAPHRAG",
    "EMBED_LLM_TOKEN":                "EMBED_LLM_TOKEN",
    "EMBED_LLM_API_BASE":             "EMBED_LLM_API_BASE",
    "EMBED_LLM_ID":                   "EMBED_LLM_ID",
    "EMBED_LLM_PROVIDER":             "EMBED_LLM_PROVIDER",
    "EMBED_LLM_PROVIDER_GRAPHRAG":    "EMBED_LLM_PROVIDER_GRAPHRAG",
}


@dsl.container_component
def git_clone_step(repo_url: str, repo_ref: str):
    return dsl.ContainerSpec(
        image=DATA_GENERATION_IMAGE,
        command=["sh", "-c"],
        args=[(
            f'git config --global --add safe.directory {MOUNT_PATH} && '
            'if [ -n "$GIT_TOKEN" ]; then '
            "git config --global credential.helper "
            "'!f() {{ echo username=$GIT_USERNAME; echo password=$GIT_TOKEN; }}; f'; "
            'fi && '
            f'git -C {MOUNT_PATH} init && '
            f'git -C {MOUNT_PATH} remote add origin {{repo_url}} && '
            f'git -C {MOUNT_PATH} fetch origin {{repo_ref}} && '
            f'git -C {MOUNT_PATH} checkout -B {{repo_ref}} FETCH_HEAD'
        ).format(repo_url=repo_url, repo_ref=repo_ref)],
    )


@dsl.container_component
def data_generation_step(
    git_repo: str,
    git_branch: str,
    languages: str,
    source_path: str,
    target_path: str,
    max_concurrency: int,
    n_completions: int,
):
    return dsl.ContainerSpec(
        image=DATA_GENERATION_IMAGE,
        # Use the papermill Python API (not CLI) so _LANGUAGES is passed as a real
        # Python list object. The CLI always injects parameter values as strings,
        # so ['python'] becomes the string "['python']" which iterates as characters.
        # The Python API uses repr() which renders ['python'] as a list literal.
        command=["python3", "-c"],
        args=[
            (
                'import papermill as pm, sys; '
                'params = {"_GIT_REPO": sys.argv[1], "_GIT_BRANCH": sys.argv[2], '
                '"_SOURCE_PATH": sys.argv[3], "_TARGET_PATH": sys.argv[4]}; '
                'if sys.argv[5]: params["_LANGUAGES"] = [x.strip() for x in sys.argv[5].split(",")]; '
                'mc = int(sys.argv[6]); nc = int(sys.argv[7]); '
                'if mc: params["_MAX_CONCURRENCY"] = mc; '
                'if nc: params["_N_COMPLETIONS"] = nc; '
                f'pm.execute_notebook("{WORKDIR}/data_generation_graphrag_pipeline.ipynb", "/dev/null", '
                f'cwd="{WORKDIR}", log_output=True, progress_bar=False, parameters=params)'
            ),
            git_repo,         # sys.argv[1]
            git_branch,       # sys.argv[2]
            source_path,      # sys.argv[3]
            target_path,      # sys.argv[4]
            languages,        # sys.argv[5]
            max_concurrency,  # sys.argv[6]
            n_completions,    # sys.argv[7]
        ],
    )


@dsl.container_component
def data_indexing_step(codebase_path: str, graphrag_source_path: str, chunk_size: int, chunk_overlap: int):
    return dsl.ContainerSpec(
        image=DATA_INDEXING_IMAGE,
        command=["python3", "-c"],
        args=[
            (
                'import papermill as pm, sys; '
                'params = {"_CODEBASE_PATH": sys.argv[1], "_GRAPHRAG_SOURCE_PATH": sys.argv[2]}; '
                'cs = int(sys.argv[3]); co = int(sys.argv[4]); '
                'if cs: params["_CHUNK_SIZE"] = cs; '
                'if co: params["_CHUNK_OVERLAP"] = co; '
                f'pm.execute_notebook("{WORKDIR}/data_indexing_graphrag_pipeline.ipynb", "/dev/null", '
                f'cwd="{WORKDIR}", log_output=True, progress_bar=False, parameters=params)'
            ),
            codebase_path,        # sys.argv[1]
            graphrag_source_path, # sys.argv[2]
            chunk_size,           # sys.argv[3]
            chunk_overlap,        # sys.argv[4]
        ],
    )


@dsl.container_component
def tar_step(graphrag_source_path: str, target_path: str):
    return dsl.ContainerSpec(
        image="registry.access.redhat.com/ubi9",
        command=["sh", "-c"],
        args=[(
            f"cd {WORKDIR} && tar -czf graphrag-index.tar.gz "
            f"--exclude={{graphrag_source_path}}/settings.yaml "
            f"{{graphrag_source_path}}/ {{target_path}}/"
        ).format(graphrag_source_path=graphrag_source_path, target_path=target_path)],
    )


@dsl.component(base_image="python:3.9-slim")
def export_index_artifact(workdir: str, index_artifact: dsl.Output[dsl.Artifact]):
    import shutil
    shutil.copy(f"{workdir}/graphrag-index.tar.gz", index_artifact.path)


@dsl.pipeline(
    name="code-understanding-pipeline",
    description="Clone repo, generate GraphRAG metadata, build index, and tar output",
)
def code_understanding_pipeline(
    pvc_name:             str = "",
    repo_url:             str = "",
    repo_ref:             str = "main",
    git_repo:             str = "",
    git_branch:           str = "main",
    languages:            str = "",
    source_path:          str = "source",
    target_path:          str = "target",
    graphrag_source_path: str = "graph_rag_app/source",
    max_concurrency:      int = 0,
    n_completions:        int = 0,
    chunk_size:           int = 0,
    chunk_overlap:        int = 0,
):
    clone = git_clone_step(repo_url=repo_url, repo_ref=repo_ref)
    mount_pvc(clone, pvc_name=pvc_name, mount_path=MOUNT_PATH)
    use_secret_as_env(clone, secret_name=GIT_SECRET_NAME, secret_key_to_env=GIT_SECRET_ENV_VARS)

    gen = data_generation_step(
        git_repo=git_repo,
        git_branch=git_branch,
        languages=languages,
        source_path=source_path,
        target_path=target_path,
        max_concurrency=max_concurrency,
        n_completions=n_completions,
    ).after(clone)
    mount_pvc(gen, pvc_name=pvc_name, mount_path=MOUNT_PATH)
    use_secret_as_env(gen, secret_name=LLM_SECRET_NAME, secret_key_to_env=LLM_ENV_VARS)

    idx = data_indexing_step(
        codebase_path=target_path,
        graphrag_source_path=graphrag_source_path,
        chunk_size=chunk_size,
        chunk_overlap=chunk_overlap,
    ).after(gen)
    mount_pvc(idx, pvc_name=pvc_name, mount_path=MOUNT_PATH)
    use_secret_as_env(idx, secret_name=LLM_SECRET_NAME, secret_key_to_env=LLM_ENV_VARS)

    tar = tar_step(graphrag_source_path=graphrag_source_path, target_path=target_path).after(idx)
    mount_pvc(tar, pvc_name=pvc_name, mount_path=MOUNT_PATH)

    export = export_index_artifact(workdir=WORKDIR).after(tar)
    mount_pvc(export, pvc_name=pvc_name, mount_path=MOUNT_PATH)


if __name__ == "__main__":
    here = os.path.dirname(os.path.abspath(__file__))
    output = os.environ.get(
        "PIPELINE_OUTPUT",
        os.path.normpath(os.path.join(here, "../../../helm/files/code_understanding_pipeline.yaml")),
    )
    compiler.Compiler().compile(code_understanding_pipeline, output)
