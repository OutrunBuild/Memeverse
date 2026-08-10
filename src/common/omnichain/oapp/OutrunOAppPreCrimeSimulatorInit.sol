// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.35;

import {IPreCrime} from "@layerzerolabs/oapp-evm/contracts/precrime/interfaces/IPreCrime.sol";
import {
    IOAppPreCrimeSimulator,
    InboundPacket,
    Origin
} from "@layerzerolabs/oapp-evm/contracts/precrime/interfaces/IOAppPreCrimeSimulator.sol";

import {OutrunOwnableInit} from "../../access/OutrunOwnableInit.sol";

/**
 * @title OutrunOAppPreCrimeSimulatorInit (Just for minimal proxy)
 * @dev Abstract contract serving as the base for preCrime simulation functionality in an OApp.
 */
abstract contract OutrunOAppPreCrimeSimulatorInit is IOAppPreCrimeSimulator, OutrunOwnableInit {
    struct OAppPreCrimeSimulatorStorage {
        // preCrime = LayerZero 预执行安全检查：verifier 在消息真实投递前，在本链预模拟入站消息执行，
        // 并把模拟结果与其它链的结果比对——若揭示恶意状态转移，则拦截该次真实投递。preCrime 实现地址存于此。
        address preCrime;
    }

    // keccak256(abi.encode(uint256(keccak256("outrun.layerzerov2.storage.OAppPreCrimeSimulator")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant OAPP_PRE_CRIME_SIMULATOR_STORAGE_LOCATION =
        0x64ee1c09e489d82d98a23ae0880bbc36a3637a4a59e3c120b24b8998a504ab00;

    function _getOAppPreCrimeSimulatorStorage() internal pure returns (OAppPreCrimeSimulatorStorage storage $) {
        assembly {
            $.slot := OAPP_PRE_CRIME_SIMULATOR_STORAGE_LOCATION
        }
    }

    /**
     * @dev Ownable is not initialized here on purpose. It should be initialized in the child contract to
     * accommodate the different version of Ownable.
     */
    function __OutrunOAppPreCrimeSimulator_init() internal onlyInitializing {}

    /// @dev Form-compat stub: mirrors the upstream full/`_unchained` initializer pair convention
    ///      this file ports. Empty and unwired in the production init chain; kept for convention.
    function __OutrunOAppPreCrimeSimulator_init_unchained() internal onlyInitializing {}

    /// @notice Reads the preCrime contract currently wired into the simulator.
    /// @dev Returns the zero address when simulation checks are disabled.
    /// @return preCrimeAddress Address of preCrime implementation.
    function preCrime() external view override returns (address) {
        OAppPreCrimeSimulatorStorage storage $ = _getOAppPreCrimeSimulatorStorage();
        return $.preCrime;
    }

    /// @notice Exposes the OApp address that simulation should treat as the execution target.
    /// @dev This base implementation simply points back to `address(this)`.
    /// @return oAppAddress OApp address used for simulation context.
    function oApp() external view virtual returns (address) {
        return address(this);
    }

    /// @notice Sets the preCrime contract address.
    /// @dev Callable only by owner.
    /// @param _preCrime Address of preCrime implementation.
    function setPreCrime(address _preCrime) public virtual onlyOwner {
        OAppPreCrimeSimulatorStorage storage $ = _getOAppPreCrimeSimulatorStorage();
        $.preCrime = _preCrime;
        emit PreCrimeSet(_preCrime);
    }

    /// @notice Simulates inbound packets and always reverts with aggregated result.
    /// @dev Intended for verifier execution in preCrime flow.
    /// @param _packets Packets to replay through `_lzReceiveSimulate`.
    function lzReceiveAndRevert(InboundPacket[] calldata _packets) public payable virtual {
        uint256 packetsLength = _packets.length;
        for (uint256 i = 0; i < packetsLength; ++i) {
            InboundPacket calldata packet = _packets[i];

            // Ignore packets that are not from trusted peers.
            if (!isPeer(packet.origin.srcEid, packet.origin.sender)) continue;

            // @dev Because a verifier is calling this function, it doesnt have access to executor params:
            //  - address _executor
            //  - bytes calldata _extraData
            // preCrime will NOT work for OApps that rely on these two parameters inside of their _lzReceive().
            // They are instead stubbed to default values, address(0) and bytes("")
            // @dev Calling this.lzReceiveSimulate removes ability for assembly return 0 callstack exit,
            // which would cause the revert to be ignored.
            this.lzReceiveSimulate{value: packet.value}(
                packet.origin, packet.guid, packet.message, packet.executor, packet.extraData
            );
        }

        // @dev Revert with the simulation results. msg.sender must implement IPreCrime.buildSimulationResult().
        revert SimulationResult(IPreCrime(msg.sender).buildSimulationResult());
    }

    /// @notice Entry used by simulator to invoke `_lzReceiveSimulate`.
    /// @dev Can only be called by the contract itself during simulation replay.
    /// @param _origin Message origin metadata.
    /// @param _guid Unique message identifier.
    /// @param _message Encoded LayerZero payload.
    /// @param _executor Off-chain executor address.
    /// @param _extraData Additional executor-supplied data.
    function lzReceiveSimulate(
        Origin calldata _origin,
        bytes32 _guid,
        bytes calldata _message,
        address _executor,
        bytes calldata _extraData
    ) external payable virtual {
        // @dev Ensure ONLY can be called 'internally'.
        if (msg.sender != address(this)) revert OnlySelf();
        _lzReceiveSimulate(_origin, _guid, _message, _executor, _extraData);
    }

    /**
     * @dev Internal function to handle the OAppPreCrimeSimulator simulated receive.
     * @param _origin The origin information.
     *  - srcEid: The source chain endpoint ID.
     *  - sender: The sender address from the src chain.
     *  - nonce: The nonce of the LayerZero message.
     * @param _guid The GUID of the LayerZero message.
     * @param _message The LayerZero message.
     * @param _executor The address of the off-chain executor.
     * @param _extraData Arbitrary data passed by the msg executor.
     *
     * @dev Enables the preCrime simulator to mock sending lzReceive() messages,
     * routes the msg down from the OAppPreCrimeSimulator, and back up to the OAppReceiver.
     */
    function _lzReceiveSimulate(
        Origin calldata _origin,
        bytes32 _guid,
        bytes calldata _message,
        address _executor,
        bytes calldata _extraData
    ) internal virtual;

    /// @notice Reports whether an inbound peer is trusted for a given endpoint.
    /// @dev The simulator skips packets from untrusted sources before replaying them.
    /// @param _eid LayerZero endpoint ID.
    /// @param _peer Encoded peer address.
    /// @return trusted True when peer is accepted for `_eid`.
    function isPeer(uint32 _eid, bytes32 _peer) public view virtual returns (bool);
}
