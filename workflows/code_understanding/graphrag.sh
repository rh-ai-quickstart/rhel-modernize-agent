echo "Initializing GraphRAG index..."
python -m graphrag init --force --root $1 2>&1

echo "Removing default graphrag prompts to ensure custom prompts are used..."
rm -f $1/prompts/extract_graph.txt

echo "Copying settings.yaml..."
cp templates/settings.yaml $1/settings.yaml
sleep 5

echo "Populating GraphRAG index..."
python -m graphrag index --root $1 2>&1