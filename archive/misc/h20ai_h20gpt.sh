
# https://github.com/h2oai/h2ogpt?tab=readme-ov-file#macos-cpum1m2-with-full-document-qa-capability
# https://github.com/h2oai/h2ogpt?tab=readme-ov-file
# https://llama-cpp-python.readthedocs.io/en/latest/install/macos/

# https://github.com/imartinez/penpotfest_workshop

https://github.com/h2oai/h2ogpt
export PIP_EXTRA_INDEX_URL="https://download.pytorch.org/whl/cpu"
# for windows/mac use "set" or relevant environment setting mechanism
export CMAKE_ARGS="-DLLAMA_METAL=on"
export FORCE_CMAKE=1

# https://llama-cpp-python.readthedocs.io/en/latest/install/macos/

# commands on any system:
   # ```bash
   git clone https://github.com/h2oai/h2ogpt.git
   cd h2ogpt
   pip install -r requirements.txt
   pip install -r reqs_optional/requirements_optional_langchain.txt

   pip uninstall llama_cpp_python llama_cpp_python_cuda -y
   pip install -r reqs_optional/requirements_optional_llamacpp_gpt4all.txt --no-cache-dir

   pip install -r reqs_optional/requirements_optional_langchain.urls.txt
   # GPL, only run next line if that is ok:
   pip install -r reqs_optional/requirements_optional_langchain.gpllike.txt

   # choose up to 32768 if have enough GPU memory:
   python generate.py --base_model=TheBloke/Mistral-7B-Instruct-v0.2-GGUF --prompt_type=mistral --max_seq_len=4096