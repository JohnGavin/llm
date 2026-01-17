# https://www.infoworld.com/article/3705035/5-easy-ways-to-run-an-llm-locally.html


# /Users/johngavin/docs_gh/llm
 brew install llm
 llm install llm-gpt4all

llm models list
# llm -m the-model-name "Your query"
llm models list | grep falcon
llm -m gpt4all-falcon-newbpe-q4_0 "Tell me a joke about computer programming"
# llm -m all-MiniLM-L6-v2-f16 "what is wikipedia"
# llm -m all-MiniLM-L6-v2 "what is wikipedia"
# llm -m gpt-3.5-turbo "Tell me a joke about computer programming"
#   exceeded your current quota, please check your plan and billing details.
# https://github.com/simonw/llm-llama-cpp
# llama-2-7b-chat Mac with the M1 Pro chip and just 16GB of RAM

llm aliases
llm aliases | grep falcon
llm aliases set falcon gpt4all-falcon-newbpe-q4_0
llm aliases | grep falcon


# argument flag that lets you continue from a prior chat 
#  and the ability to use it within a Python script. 
# https://simonwillison.net/2023/Sep/4/llm-embeddings/
#  search for related documents.