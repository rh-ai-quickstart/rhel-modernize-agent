import os
from kfp import dsl, compiler
from kfp.kubernetes import mount_pvc, use_secret_as_env

MOUNT_PATH = "/opt/app-root/src"
WORKDIR = "/opt/app-root/src/workflows/code_understanding"

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
        image=DATA_INDEXING_IMAGE,
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
def extract_step(index_tar: str):
    return dsl.ContainerSpec(
        image="registry.access.redhat.com/ubi9",
        command=["sh", "-c"],
        args=[(
            # Poll until the tar appears — the external uploader writes it after git_clone_step
            # creates the directory, but scheduling of this step may beat the upload.
            f'until [ -f {WORKDIR}/{{index_tar}} ]; do '
            'echo "Waiting for index tar to be uploaded..."; sleep 10; '
            f'done && cd {WORKDIR} && tar -xzf {{index_tar}}'
        ).format(index_tar=index_tar)],
    )


@dsl.container_component
def prepare_config_step():
    """Re-generate settings.yaml from the template using current env vars.

    The tar extracted by extract_step contains a settings.yaml with credentials
    frozen at index time.  This step overwrites it with a fresh substitution so
    the analysis always uses the live credentials from the mounted secret.
    """
    return dsl.ContainerSpec(
        image=DATA_INDEXING_IMAGE,
        command=["python3", "-c"],
        args=[(
            "import string, os, re; "
            f"tmpl = open('{WORKDIR}/templates/settings.yaml.in').read(); "
            "out = string.Template(tmpl).safe_substitute(os.environ); "
            "out = re.sub(r'\\$\\{\\w+\\}', '0', out); "
            f"open('{WORKDIR}/graph_rag_app/source/settings.yaml', 'w').write(out); "
            "print('settings.yaml refreshed')"
        )],
    )


@dsl.container_component
def analysis_step(graphrag_source_path: str, question: str, output_dir: str, community_level: int):
    return dsl.ContainerSpec(
        image=DATA_INDEXING_IMAGE,
        command=["python3", "-c"],
        args=[
            (
                'import papermill as pm, sys; '
                'cl = int(sys.argv[4]); '
                'params = {k: v for k, v in [("_GRAPHRAG_SOURCE_PATH", sys.argv[1]), ("_OUTPUT_DIR", sys.argv[2]), ("_QUESTION", sys.argv[3]), ("_COMMUNITY_LEVEL", cl)] if v}; '
                f'pm.execute_notebook("{WORKDIR}/data_analysis_graphrag_pipeline.ipynb", "/dev/null", '
                f'cwd="{WORKDIR}", log_output=True, progress_bar=False, parameters=params)'
            ),
            graphrag_source_path, # sys.argv[1]
            output_dir,           # sys.argv[2]
            question,             # sys.argv[3]
            community_level,      # sys.argv[4]
        ],
    )


@dsl.pipeline(
    name="code-analysis-pipeline",
    description="Clone repo, extract GraphRAG index, run analysis notebook, write reports",
)
def code_analysis_pipeline(
    pvc_name:             str = "",
    repo_url:             str = "",
    repo_ref:             str = "main",
    index_tar:            str = "graphrag-index.tar.gz",
    graphrag_source_path: str = "",
    question:             str = "",
    output_dir:           str = "",
    community_level:      int = 0,
):
    clone = git_clone_step(repo_url=repo_url, repo_ref=repo_ref)
    mount_pvc(clone, pvc_name=pvc_name, mount_path=MOUNT_PATH)
    use_secret_as_env(clone, secret_name=GIT_SECRET_NAME, secret_key_to_env=GIT_SECRET_ENV_VARS)

    extract = extract_step(index_tar=index_tar).after(clone)
    mount_pvc(extract, pvc_name=pvc_name, mount_path=MOUNT_PATH)

    prep = prepare_config_step().after(extract)
    mount_pvc(prep, pvc_name=pvc_name, mount_path=MOUNT_PATH)
    use_secret_as_env(prep, secret_name=LLM_SECRET_NAME, secret_key_to_env=LLM_ENV_VARS)

    analysis = analysis_step(
        graphrag_source_path=graphrag_source_path,
        question=question,
        output_dir=output_dir,
        community_level=community_level,
    ).after(prep)
    mount_pvc(analysis, pvc_name=pvc_name, mount_path=MOUNT_PATH)
    use_secret_as_env(analysis, secret_name=LLM_SECRET_NAME, secret_key_to_env=LLM_ENV_VARS)


if __name__ == "__main__":
    here = os.path.dirname(os.path.abspath(__file__))
    output = os.environ.get(
        "PIPELINE_OUTPUT",
        os.path.normpath(os.path.join(here, "../../../helm/files/code_analysis_pipeline.yaml")),
    )
    compiler.Compiler().compile(code_analysis_pipeline, output)
