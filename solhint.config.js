module.exports = {
    extends: "solhint:recommended",
    rules: {
        "compiler-version": ["error", "^0.8.24"],
        "func-name-mixedcase": "off",
        "func-visibility": ["error", { ignoreConstructors: true }],
        "function-max-lines": "off",
        "gas-calldata-parameters": "error",
        "gas-indexed-events": "off",
        "gas-increment-by-one": "error",
        "gas-length-in-loops": "error",
        "gas-multitoken1155": "error",
        // erc7201() namespace strings hash to a single bytes32 slot via keccak256, so the
        // multi-slot gas heuristic false-positives on `layout at erc7201("...")` declarations —
        // currently the only >32-byte string literals in src/, so the rule is pure noise.
        "gas-small-strings": "off",
        "gas-strict-inequalities": "off",
        "gas-struct-packing": "off",
        "immutable-vars-naming": "off",
        "import-path-check": "off",
        "max-states-count": "off",
        "no-empty-blocks": "off",
        "no-inline-assembly": "off",
        "reason-string": "off",
        "use-natspec": "off",
        "var-name-mixedcase": "off"
    }
};
