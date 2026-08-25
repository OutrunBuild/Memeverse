// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.35;

import {OApp, Origin} from "@layerzerolabs/oapp-evm/contracts/oapp/OApp.sol";
import {OptionsBuilder} from "@layerzerolabs/oapp-evm/contracts/oapp/libs/OptionsBuilder.sol";
import {MessagingFee} from "@layerzerolabs/lz-evm-protocol-v2/contracts/interfaces/ILayerZeroEndpointV2.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

import {MemeverseRegistrarAbstract} from "./MemeverseRegistrarAbstract.sol";
import {IMemeverseRegistrationCenter} from "../interfaces/IMemeverseRegistrar.sol";
import {IMemeverseRegistrarOmnichain} from "../interfaces/IMemeverseRegistrarOmnichain.sol";

/**
 * @title Omnichain MemeverseRegistrar for deploying memecoin and registering memeverse
 */
contract MemeverseRegistrarOmnichain is IMemeverseRegistrarOmnichain, MemeverseRegistrarAbstract, OApp {
    using OptionsBuilder for bytes;

    uint32 public immutable REGISTRATION_CENTER_EID;
    uint32 public immutable REGISTRATION_CENTER_CHAINID;

    RegistrationGasLimit public registrationGasLimit;

    constructor(
        address _owner,
        address _localEndpoint,
        address _memeverseLauncher,
        address _lzEndpointRegistry,
        uint32 _registrationCenterEid,
        uint32 _registrationCenterChainid,
        uint80 _baseRegistrationGasLimit,
        uint80 _localRegistrationGasLimit,
        uint80 _omnichainRegistrationGasLimit
    ) MemeverseRegistrarAbstract(_owner, _memeverseLauncher, _lzEndpointRegistry) OApp(_localEndpoint, _owner) {
        REGISTRATION_CENTER_EID = _registrationCenterEid;
        REGISTRATION_CENTER_CHAINID = _registrationCenterChainid;

        registrationGasLimit = RegistrationGasLimit({
            baseRegistrationGasLimit: _baseRegistrationGasLimit,
            localRegistrationGasLimit: _localRegistrationGasLimit,
            omnichainRegistrationGasLimit: _omnichainRegistrationGasLimit
        });
    }

    /// @notice Ownership renunciation is permanently disabled.
    /// @dev Shared-`Ownable` diamond: `MemeverseRegistrarAbstract` and the OApp stack both inherit
    ///      the same OZ `Ownable`, so the leaf must disambiguate and re-pin the abstract's
    ///      always-revert override, keeping the repo-wide never-renounceable ownership invariant.
    function renounceOwnership() public override(Ownable, MemeverseRegistrarAbstract) {
        revert OwnershipRenounceDisabled();
    }

    /// @notice Quotes the LayerZero fee for sending a registration request to the center chain.
    /// @dev `value` is encoded into the executor receive option so the center-chain receive path can forward native
    /// value when it fans the registration back out to other chains.
    /// @param param Registration request to send to the center chain.
    /// @param value Native-drop value encoded into the center-chain receive options.
    /// @return lzFee Native LayerZero fee for the registrar-to-center send.
    function quoteRegister(IMemeverseRegistrationCenter.RegistrationParam calldata param, uint128 value)
        external
        view
        override
        returns (uint256 lzFee)
    {
        (,, lzFee) = _registrationGasOptions(param, value);
    }

    /// @notice Sends a registration request from a remote chain to the center chain.
    /// @dev The supplied `value` must match the value used during quoting because it is part of the LayerZero receive
    /// options for the center-chain execution.
    /// @param param Registration request to send.
    /// @param value Native-drop value encoded into the center-chain receive options.
    function registerAtCenter(IMemeverseRegistrationCenter.RegistrationParam calldata param, uint128 value)
        external
        payable
        override
    {
        (bytes memory message, bytes memory options, uint256 lzFee) = _registrationGasOptions(param, value);
        require(msg.value >= lzFee, InsufficientLzFee());

        _lzSend(
            REGISTRATION_CENTER_EID, message, options, MessagingFee({nativeFee: msg.value, lzTokenFee: 0}), msg.sender
        );
    }

    /// @notice Updates the gas schedule used to quote and send registration messages.
    /// @dev Only callable by the owner.
    /// @param _registrationGasLimit New per-hop gas schedule for registrar-to-center registration sends.
    function setRegistrationGasLimit(RegistrationGasLimit calldata _registrationGasLimit) external override onlyOwner {
        registrationGasLimit = _registrationGasLimit;

        emit SetRegistrationGasLimit(_registrationGasLimit);
    }

    function _lzReceive(
        Origin calldata,
        /*_origin*/
        bytes32,
        /*_guid*/
        bytes calldata _message,
        address,
        /*_executor*/
        bytes calldata /*_extraData*/
    )
        internal
        virtual
        override
    {
        MemeverseParam memory param = abi.decode(_message, (MemeverseParam));
        _registerMemeverse(param);
    }

    /// @dev Builds the registrar-to-center message/options and quotes the native LayerZero fee. Single source
    ///      shared by `quoteRegister` (pre-quote) and `registerAtCenter` (execute) so the fee told to the caller
    ///      and the fee enforced at send always derive from one definition. `value` is the native-drop amount
    ///      encoded into the receive options; `msg.value` (used by the caller to fund the send) is handled by
    ///      `registerAtCenter`, not here.
    function _registrationGasOptions(IMemeverseRegistrationCenter.RegistrationParam calldata param, uint128 value)
        private
        view
        returns (bytes memory message, bytes memory options, uint256 lzFee)
    {
        message = abi.encode(param);
        uint256 length = param.omnichainIds.length;
        RegistrationGasLimit memory _registrationGasLimit = registrationGasLimit;
        uint80 gasLimit = _registrationGasLimit.baseRegistrationGasLimit;
        for (uint256 i = 0; i < length;) {
            if (param.omnichainIds[i] == REGISTRATION_CENTER_CHAINID) {
                gasLimit += _registrationGasLimit.localRegistrationGasLimit;
            } else {
                gasLimit += _registrationGasLimit.omnichainRegistrationGasLimit;
            }
            unchecked {
                ++i;
            }
        }

        options = OptionsBuilder.newOptions().addExecutorLzReceiveOption(gasLimit, value);
        lzFee = _quote(REGISTRATION_CENTER_EID, message, options, false).nativeFee;
    }
}
