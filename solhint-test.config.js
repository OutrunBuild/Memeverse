const base = require("./solhint.config");

module.exports = {
    ...base,
    rules: {
        ...base.rules,
        "avoid-low-level-calls": "off",
        "check-send-result": "off",
        "gas-custom-errors": "off",
        "gas-calldata-parameters": "off",
        "gas-increment-by-one": "off",
        "gas-length-in-loops": "off",
        "gas-strict-inequalities": "off",
        "gas-small-strings": "off",
        "multiple-sends": "off",
        "no-complex-fallback": "off",
        "no-console": "off",
        "one-contract-per-file": "off",
        // Tests intentionally exercise the tx.origin identity root used by the hook
        // (e.g. HookIntegration quotes). Kept off for tests only so src/ misuse stays visible.
        "avoid-tx-origin": "off",
        // Test mocks deliberately simulate reentrancy attacks (BeforeSwapReenterer, SettlementSettleReenterer).
        "reentrancy": "off",
        // Test mock names like MockERC20Like describe ERC20-like behaviour, not a pure interface.
        "interface-starts-with-i": "off",
        // Test constants like OwnableUnauthorizedAccountSelector mirror OZ source naming on purpose.
        "const-name-snakecase": "off"
    }
};
