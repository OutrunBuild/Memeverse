// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.35;

/// @title MockPreCrimeCaller
/// @notice Stand-in for the LayerZero verifier that calls `lzReceiveAndRevert`.
/// @dev `lzReceiveAndRevert` reverts with `SimulationResult(IPreCrime(msg.sender).buildSimulationResult())`,
///      so `msg.sender` must expose `buildSimulationResult`. The source casts `msg.sender` to `IPreCrime`, so
///      the mock only needs to implement the function it actually calls (duck-typed via the cast); it does not
///      declare `is IPreCrime` to avoid stubbing the four unrelated verifier functions.
contract MockPreCrimeCaller {
    /// @notice The bytes that `buildSimulationResult` hands back to the simulator.
    bytes public simulationResult;

    constructor(bytes memory simulationResult_) {
        simulationResult = simulationResult_;
    }

    /// @notice Sets the bytes returned by `buildSimulationResult`.
    /// @param simulationResult_ See implementation.
    function setSimulationResult(bytes memory simulationResult_) external {
        simulationResult = simulationResult_;
    }

    /// @notice IPreCrime hook invoked inside `lzReceiveAndRevert`'s terminal revert.
    /// @return The stored simulation result bytes.
    function buildSimulationResult() external view returns (bytes memory) {
        return simulationResult;
    }
}
