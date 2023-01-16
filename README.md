TODO:
- copy project structure of https://github.com/curvefi/curve-stablecoin with boa testing
- https://curve.readthedocs.io/guide-code-style.html


## installation

```bash
 pip install -r ape-requirements.txt   
 pip install -r boa-requirements.txt   
ape plugins install .
```
## Testing
`ape test --network=::foundry --cache-clear -v DEBUG`

# Docs
install Mermaid CLI
`https://github.com/mermaid-js/mermaid-cli`

`mmdc -i ./docs/ChikkinPonziSystem.mmd -o ./docs/ChikkinPonziSystem.svg -t dark -b transparent && open ./docs/ChikkinPonziSystem.png `