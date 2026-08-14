// SPDX-License-Identifier: GPL-3.0
/* solhint-disable one-contract-per-file */
pragma solidity ^0.8.35;

// MemeverseERC1967Proxy exists only for this deployer's circular CREATE2 governor/incentivizer flow.

import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {Create2} from "@openzeppelin/contracts/utils/Create2.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IVotes} from "@openzeppelin/contracts/governance/utils/IVotes.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {IMemeverseProxyDeployer} from "../interfaces/IMemeverseProxyDeployer.sol";
import {IMemecoinDaoGovernor} from "../../governance/interfaces/IMemecoinDaoGovernor.sol";
import {IGovernanceCycleIncentivizer} from "../../governance/interfaces/IGovernanceCycleIncentivizer.sol";

/**
 * @title Memeverse ERC1967 Proxy
 * @notice ERC1967 proxy variant used only for circular governor/incentivizer deployments.
 * @dev The paired governor and incentivizer each need the other's final CREATE2 address in their initializer.
 */
contract MemeverseERC1967Proxy is ERC1967Proxy {
    /// @notice Deploys the proxy without constructor initialization.
    /// @param implementation Initial implementation address.
    constructor(address implementation) ERC1967Proxy(implementation, "") {}

    /// @dev Deployment is followed by both initializers in the same `deployGovernorAndIncentivizer` transaction.
    function _unsafeAllowUninitialized() internal pure override returns (bool) {
        return true;
    }
}

/**
 * @title MemeverseProxyDeployer Contract
 */
contract MemeverseProxyDeployer is IMemeverseProxyDeployer, Ownable {
    using Clones for address;

    address public immutable memeverseLauncher;
    address public immutable memecoinImplementation;
    address public immutable polImplementation;
    address public immutable vaultImplementation;
    address public immutable governorImplementation;
    address public immutable incentivizerImplementation;

    uint256 public quorumNumerator;
    uint256 public minQuorumNumerator;
    uint256 public bootstrapPeriod;
    uint256 public maxTreasurySpendRatio;
    uint256 public upgradeSupermajorityRatio;

    /// @dev minQuorumNumerator is a percentage of the memecoin supply (denominator 100,
    /// applied in deployGovernorAndIncentivizer as totalSupply() * minQuorumNumerator / 100).
    /// Values above 100 demand more than 100% of the supply to reach quorum, which would
    /// permanently brick the deployed governor: _minQuorum is frozen at init with no setter,
    /// and the only upgrade path (_authorizeUpgrade) is gated by the very governance that
    /// would be paralyzed.
    error InvalidMinQuorumNumerator();

    modifier onlyMemeverseLauncher() {
        require(msg.sender == memeverseLauncher, PermissionDenied());
        _;
    }

    constructor(
        address _owner,
        address _memeverseLauncher,
        address _memecoinImplementation,
        address _polImplementation,
        address _vaultImplementation,
        address _governorImplementation,
        address _incentivizerImplementation,
        uint256 _quorumNumerator,
        uint256 _minQuorumNumerator,
        uint256 _bootstrapPeriod,
        uint256 _maxTreasurySpendRatio,
        uint256 _upgradeSupermajorityRatio
    ) Ownable(_owner) {
        require(
            _memeverseLauncher != address(0) && _memecoinImplementation != address(0)
                && _polImplementation != address(0) && _vaultImplementation != address(0)
                && _governorImplementation != address(0) && _incentivizerImplementation != address(0),
            ZeroInput()
        );
        memeverseLauncher = _memeverseLauncher;
        memecoinImplementation = _memecoinImplementation;
        polImplementation = _polImplementation;
        vaultImplementation = _vaultImplementation;
        governorImplementation = _governorImplementation;
        incentivizerImplementation = _incentivizerImplementation;
        quorumNumerator = _quorumNumerator;
        // Constructor and setter enforce the same range: >0 and <=100. See InvalidMinQuorumNumerator.
        require(_minQuorumNumerator != 0, ZeroInput());
        require(_minQuorumNumerator <= 100, InvalidMinQuorumNumerator());
        minQuorumNumerator = _minQuorumNumerator;
        bootstrapPeriod = _bootstrapPeriod;
        maxTreasurySpendRatio = _maxTreasurySpendRatio;
        upgradeSupermajorityRatio = _upgradeSupermajorityRatio;
    }

    /// @inheritdoc IMemeverseProxyDeployer
    /// @dev Uses the same clone salt and implementation as `deployYieldVault`.
    /// @param uniqueId Verse identifier used as the clone salt.
    /// @return Predicted yield-vault clone address.
    function predictYieldVaultAddress(uint256 uniqueId) external view override returns (address) {
        return vaultImplementation.predictDeterministicAddress(keccak256(abi.encode(uniqueId)));
    }

    /// @inheritdoc IMemeverseProxyDeployer
    /// @dev Uses the same Create2 salts and proxy bytecode as `deployGovernorAndIncentivizer`.
    /// @param uniqueId Verse identifier used as the Create2 salt.
    /// @return governor Predicted governor proxy address.
    /// @return incentivizer Predicted incentivizer proxy address.
    function computeGovernorAndIncentivizerAddress(uint256 uniqueId)
        external
        view
        override
        returns (address governor, address incentivizer)
    {
        governor = Create2.computeAddress(
            keccak256(abi.encode(uniqueId)),
            keccak256(abi.encodePacked(type(MemeverseERC1967Proxy).creationCode, abi.encode(governorImplementation)))
        );

        incentivizer = Create2.computeAddress(
            keccak256(abi.encode(uniqueId)),
            keccak256(
                abi.encodePacked(type(MemeverseERC1967Proxy).creationCode, abi.encode(incentivizerImplementation))
            )
        );
    }

    /// @inheritdoc IMemeverseProxyDeployer
    /// @dev Restricted to the launcher so each verse is provisioned only through the protocol flow.
    /// @param uniqueId Verse identifier used as the clone salt.
    /// @return memecoin Newly deployed memecoin clone address.
    function deployMemecoin(uint256 uniqueId) external override onlyMemeverseLauncher returns (address memecoin) {
        memecoin = memecoinImplementation.cloneDeterministic(keccak256(abi.encode(uniqueId)));

        emit DeployMemecoin(uniqueId, memecoin);
    }

    /// @inheritdoc IMemeverseProxyDeployer
    /// @dev Restricted to the launcher.
    /// @param uniqueId Verse identifier used as the clone salt.
    /// @return pol Newly deployed POL clone address.
    function deployPOL(uint256 uniqueId) external override onlyMemeverseLauncher returns (address pol) {
        pol = polImplementation.cloneDeterministic(keccak256(abi.encode(uniqueId)));

        emit DeployPOL(uniqueId, pol);
    }

    /// @inheritdoc IMemeverseProxyDeployer
    /// @dev Restricted to the launcher.
    /// @param uniqueId Verse identifier used as the clone salt.
    /// @return yieldVault Newly deployed yield-vault clone address.
    function deployYieldVault(uint256 uniqueId) external override onlyMemeverseLauncher returns (address yieldVault) {
        yieldVault = vaultImplementation.cloneDeterministic(keccak256(abi.encode(uniqueId)));

        emit DeployYieldVault(uniqueId, yieldVault);
    }

    /// @notice Deploys and initializes the verse governor together with its cycle incentivizer.
    /// @dev Both proxies are deployed deterministically from `uniqueId`, then initialized with the freshly deployed
    /// verse token contracts and the current quorum configuration.
    /// @param memecoinName Human-readable memecoin name used to derive the DAO name.
    /// @param uAsset Verse fundraising asset.
    /// @param memecoin Verse memecoin contract.
    /// @param pol Verse POL contract.
    /// @param yieldVault Verse yield-vault contract.
    /// @param uniqueId Verse identifier used as the Create2 salt.
    /// @param proposalThreshold Minimum voting power required to propose.
    /// @return governor Newly deployed governor proxy address.
    /// @return incentivizer Newly deployed incentivizer proxy address.
    function deployGovernorAndIncentivizer(
        string calldata memecoinName,
        address uAsset,
        address memecoin,
        address pol,
        address yieldVault,
        uint256 uniqueId,
        uint256 proposalThreshold
    ) external override onlyMemeverseLauncher returns (address governor, address incentivizer) {
        // Read external token state before deploying the temporarily uninitialized proxy pair.
        uint256 _minQuorum = IERC20(memecoin).totalSupply() * minQuorumNumerator / 100;

        // Deploy
        governor = Create2.deploy(
            0,
            keccak256(abi.encode(uniqueId)),
            abi.encodePacked(type(MemeverseERC1967Proxy).creationCode, abi.encode(governorImplementation))
        );
        incentivizer = Create2.deploy(
            0,
            keccak256(abi.encode(uniqueId)),
            abi.encodePacked(type(MemeverseERC1967Proxy).creationCode, abi.encode(incentivizerImplementation))
        );

        // Initialize
        IMemecoinDaoGovernor(governor)
            .initialize(
                string(abi.encodePacked(memecoinName, " DAO")),
                IVotes(yieldVault),
                1 days,
                1 weeks,
                proposalThreshold,
                quorumNumerator,
                incentivizer,
                _minQuorum,
                bootstrapPeriod,
                maxTreasurySpendRatio,
                upgradeSupermajorityRatio
            );
        address[] memory initFundTokens = new address[](4);
        initFundTokens[0] = uAsset;
        initFundTokens[1] = memecoin;
        initFundTokens[2] = pol;
        initFundTokens[3] = yieldVault;
        IGovernanceCycleIncentivizer(incentivizer).initialize(governor, initFundTokens);

        emit DeployGovernorAndIncentivizer(uniqueId, governor, incentivizer);
    }

    /// @notice Updates the quorum numerator used for future governor deployments.
    /// @dev Does not retroactively modify already deployed governors.
    /// @param _quorumNumerator New quorum numerator basis points.
    function setQuorumNumerator(uint256 _quorumNumerator) external override onlyOwner {
        require(_quorumNumerator != 0, ZeroInput());

        quorumNumerator = _quorumNumerator;

        emit SetQuorumNumerator(_quorumNumerator);
    }

    /// @notice Updates the min quorum numerator used for future governor deployments.
    /// @dev Does not retroactively modify already deployed governors. The numerator is bounded to <= 100
    /// (percent of supply); see InvalidMinQuorumNumerator.
    /// @param _minQuorumNumerator New min quorum numerator value.
    function setMinQuorumNumerator(uint256 _minQuorumNumerator) external override onlyOwner {
        require(_minQuorumNumerator != 0, ZeroInput());
        require(_minQuorumNumerator <= 100, InvalidMinQuorumNumerator());

        minQuorumNumerator = _minQuorumNumerator;

        emit SetMinQuorumNumerator(_minQuorumNumerator);
    }

    /// @notice Updates the bootstrap period used for future governor deployments.
    /// @dev Does not retroactively modify already deployed governors.
    /// @param _bootstrapPeriod New bootstrap period in seconds.
    function setBootstrapPeriod(uint256 _bootstrapPeriod) external override onlyOwner {
        require(_bootstrapPeriod != 0, ZeroInput());

        bootstrapPeriod = _bootstrapPeriod;

        emit SetBootstrapPeriod(_bootstrapPeriod);
    }

    /// @notice Updates the max treasury spend ratio used for future governor deployments.
    /// @dev Does not retroactively modify already deployed governors.
    /// @param _maxTreasurySpendRatio New max treasury spend ratio in basis points.
    function setMaxTreasurySpendRatio(uint256 _maxTreasurySpendRatio) external override onlyOwner {
        require(_maxTreasurySpendRatio != 0, ZeroInput());

        maxTreasurySpendRatio = _maxTreasurySpendRatio;

        emit SetMaxTreasurySpendRatio(_maxTreasurySpendRatio);
    }

    /// @notice Updates the upgrade supermajority ratio used for future governor deployments.
    /// @dev Does not retroactively modify already deployed governors.
    /// @param _upgradeSupermajorityRatio New upgrade supermajority ratio in basis points.
    function setUpgradeSupermajorityRatio(uint256 _upgradeSupermajorityRatio) external override onlyOwner {
        require(_upgradeSupermajorityRatio != 0, ZeroInput());

        upgradeSupermajorityRatio = _upgradeSupermajorityRatio;

        emit SetUpgradeSupermajorityRatio(_upgradeSupermajorityRatio);
    }
}
