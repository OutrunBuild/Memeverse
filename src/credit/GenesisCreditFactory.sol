// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.35;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {CREATE3} from "solmate/utils/CREATE3.sol";

import {IGenesisCreditFactory} from "./interfaces/IGenesisCreditFactory.sol";
import {GenesisCredit} from "./GenesisCredit.sol";

/**
 * @title GenesisCreditFactory
 * @notice Owner-gated factory that deploys GenesisCredit tokens via CREATE3.
 * @dev Each credit token is keyed by its `uAsset`: the CREATE3 salt is `keccak256(abi.encode(uAsset))`
 *      and the factory delegates to solmate's `CREATE3` library (deployer = `address(this)`), so the CREATE3 namespace is the
 *      factory's own address. Each credit address is therefore
 *      `CREATE3.getDeployed(factory, keccak256(uAsset))` and is fully determined by the factory
 *      address plus `uAsset`. Because GenesisCredit is a plain (non-initializable) OFT, the full
 *      contract bytecode is deployed in one CREATE3 call and its constructor runs in-line; no
 *      separate implementation provisioning or initialize step is needed.
 *
 *      Ownership: this factory is OZ `Ownable` (non-upgradeable) and gates `deployCredit` behind
 *      `onlyOwner`. There is no separate deployer contract to own, so no ownership transfer is
 *      required before first deployment.
 */
contract GenesisCreditFactory is IGenesisCreditFactory, Ownable {
    /// @notice LayerZero endpoint address baked into every deployed credit token.
    address public immutable lzEndpoint;

    /// @notice LayerZero home-chain eid baked into every deployed credit token.
    uint32 public immutable homeChainEid;

    /// @notice Registry of already-deployed credit tokens keyed by uAsset; address(0) means not deployed.
    mapping(address => address) private registry;

    /// @notice Reverts when ownership renunciation is attempted.
    /// @dev Repo invariant: ownership is never renounceable.
    error OwnershipRenounceDisabled();

    /// @notice Construct the factory, baking the LayerZero endpoint, home-chain eid, and owner
    ///         into immutable state that every deployed credit token inherits.
    /// @param lzEndpoint_ LayerZero endpoint address forwarded to every credit constructor.
    /// @param homeChainEid_ LayerZero endpoint id of the home chain where claims are allowed.
    /// @param owner_ Initial owner of this factory (gates deployCredit).
    constructor(address lzEndpoint_, uint32 homeChainEid_, address owner_) Ownable(owner_) {
        require(lzEndpoint_ != address(0), ZeroAddress());
        // Zero eid would bake a permanently reverting claim gate (endpoint.eid() != 0 on every
        // real chain) into every credit this factory deploys; fail fast at construction.
        require(homeChainEid_ != 0, ZeroHomeChainEid());
        lzEndpoint = lzEndpoint_;
        homeChainEid = homeChainEid_;
    }

    /// @inheritdoc IGenesisCreditFactory
    function deployCredit(address uAsset, string calldata name, string calldata symbol, address delegate)
        external
        override
        onlyOwner
        returns (address credit)
    {
        require(uAsset != address(0), ZeroUAsset());
        require(delegate != address(0), ZeroDelegate());
        require(registry[uAsset] == address(0), AlreadyDeployed());

        // GenesisCredit is fixed at 18 decimals, so credit-path raw-unit 1:1 accounting only holds
        // when the uAsset is also 18 decimals. Reject non-18-dec uAssets at the creation boundary so
        // a 6-dec uAsset can never get a fixed-18-dec credit token whose raw units it would misread.
        uint8 uAssetDecimals = IERC20Metadata(uAsset).decimals();
        if (uAssetDecimals != 18) revert InvalidUAssetDecimals(uAssetDecimals, 18);

        // Salt is a pure function of uAsset -> CREATE3 address is deterministic and stable.
        bytes32 salt = keccak256(abi.encode(uAsset));
        // Constructor args appended to the creation code run in-line at CREATE3 deployment.
        bytes memory code = abi.encodePacked(
            type(GenesisCredit).creationCode, abi.encode(name, symbol, lzEndpoint, delegate, homeChainEid)
        );
        // Reentrancy is benign: deployCredit is onlyOwner, CREATE3.deploy transfers no value, and
        // registry[uAsset]==0 is enforced before deploy. A reentrant deploy with the same uAsset
        // also reverts: the same salt re-CREATE2s an existing address, so CREATE3.deploy fails.
        // Disable both detectors — slither anchors
        // reentrancy-no-eth on the external call line and reentrancy-events on the emit line.
        // slither-disable-next-line reentrancy-no-eth
        credit = CREATE3.deploy(salt, code, 0);

        registry[uAsset] = credit;
        // slither-disable-next-line reentrancy-events
        emit CreditDeployed(uAsset, credit);
    }

    /// @inheritdoc IGenesisCreditFactory
    function predictCredit(address uAsset) public view override returns (address credit) {
        // CREATE3.getDeployed namespaces by deployer (this factory) and the uAsset-derived salt.
        return CREATE3.getDeployed(keccak256(abi.encode(uAsset)));
    }

    /// @inheritdoc IGenesisCreditFactory
    function creditOf(address uAsset) external view override returns (address credit) {
        return registry[uAsset];
    }

    /// @notice Ownership renunciation is permanently disabled.
    /// @dev The OZ `Ownable` base exposes `renounceOwnership`; this override makes it always revert,
    ///      keeping the repo-wide never-renounceable ownership invariant.
    function renounceOwnership() public override {
        revert OwnershipRenounceDisabled();
    }
}
