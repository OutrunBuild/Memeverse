// SPDX-License-Identifier: GPL-3.0
// Compatible with OpenZeppelin Contracts ^5.0.0
pragma solidity ^0.8.35;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {GovernorUpgradeable} from "@openzeppelin/contracts-upgradeable/governance/GovernorUpgradeable.sol";
import {
    GovernorVotesUpgradeable
} from "@openzeppelin/contracts-upgradeable/governance/extensions/GovernorVotesUpgradeable.sol";
import {
    GovernorStorageUpgradeable
} from "@openzeppelin/contracts-upgradeable/governance/extensions/GovernorStorageUpgradeable.sol";
import {
    GovernorSettingsUpgradeable
} from "@openzeppelin/contracts-upgradeable/governance/extensions/GovernorSettingsUpgradeable.sol";
import {
    GovernorCountingFractionalUpgradeable
} from "@openzeppelin/contracts-upgradeable/governance/extensions/GovernorCountingFractionalUpgradeable.sol";
import {
    GovernorVotesQuorumFractionUpgradeable
} from "@openzeppelin/contracts-upgradeable/governance/extensions/GovernorVotesQuorumFractionUpgradeable.sol";

import {OutrunSafeERC20} from "../common/token/OutrunSafeERC20.sol";
import {IVotes, IMemecoinDaoGovernor} from "./interfaces/IMemecoinDaoGovernor.sol";
import {IGovernanceCycleIncentivizer} from "./interfaces/IGovernanceCycleIncentivizer.sol";

/**
 * @title Memecoin DAO Governor
 * @notice This contract is a modified version of the GovernorUpgradeable contract from OpenZeppelin.
 * @dev It is used to manage the DAO of the Memecoin project, also as Memecoin DAO Treasury.
 */
// solhint-disable-next-line gas-small-strings
contract MemecoinDaoGovernorUpgradeable layout at erc7201("outrun.storage.MemecoinDaoGovernor")
    is
    IMemecoinDaoGovernor,
    Initializable,
    GovernorUpgradeable,
    GovernorSettingsUpgradeable,
    GovernorCountingFractionalUpgradeable,
    GovernorStorageUpgradeable,
    GovernorVotesUpgradeable,
    GovernorVotesQuorumFractionUpgradeable,
    UUPSUpgradeable
{
    using OutrunSafeERC20 for IERC20;

    /// @custom:storage-location erc7201:outrun.storage.MemecoinDaoGovernor
    struct MemecoinDaoGovernorStorage {
        IGovernanceCycleIncentivizer _governanceCycleIncentivizer;
        mapping(address => uint256) userUnfinalizedProposalId;
        uint256 _minQuorum;
        uint256 _governanceStartTime;
        uint256 _maxTreasurySpendRatio;
        uint256 _upgradeSupermajorityRatio;
        bool _executionActive;
        uint256 _executionOperationCount;
    }

    MemecoinDaoGovernorStorage private memecoinDaoGovernorStorage;

    function __MemecoinDaoGovernor_init(
        address _governanceCycleIncentivizer,
        uint256 _minQuorum,
        uint256 _bootstrapPeriod,
        uint256 _maxTreasurySpendRatio,
        uint256 _upgradeSupermajorityRatio
    ) internal onlyInitializing {
        require(
            _maxTreasurySpendRatio > 0 && _maxTreasurySpendRatio <= 10000 && _upgradeSupermajorityRatio > 0
                && _upgradeSupermajorityRatio <= 10000,
            InvalidGovernanceParams()
        );
        memecoinDaoGovernorStorage._governanceCycleIncentivizer =
            IGovernanceCycleIncentivizer(_governanceCycleIncentivizer);
        memecoinDaoGovernorStorage._minQuorum = _minQuorum;
        memecoinDaoGovernorStorage._governanceStartTime = block.timestamp + _bootstrapPeriod;
        memecoinDaoGovernorStorage._maxTreasurySpendRatio = _maxTreasurySpendRatio;
        memecoinDaoGovernorStorage._upgradeSupermajorityRatio = _upgradeSupermajorityRatio;
    }

    constructor() {
        _disableInitializers();
    }

    /**
     * @notice Initialize the governor with voting settings and the incentivizer reference.
     * @dev Wires the OpenZeppelin governor mixins and stores the incentivizer address.
     * @param _name The governor's name exposed to off-chain tooling.
     * @param _token The vote token used for proposals and voting.
     * @param _votingDelay Voting delay in governor clock units (seconds under the vault's timestamp clock).
     * @param _votingPeriod Voting period in governor clock units (seconds under the vault's timestamp clock).
     * @param _proposalThreshold Minimum voting power required to propose.
     * @param _quorumNumerator Fractional quorum numerator for governance decisions.
     * @param _governanceCycleIncentivizer Address of the incentivizer that tracks cycle rewards.
     * @param _minQuorum Absolute minimum quorum floor based on total supply.
     * @param _bootstrapPeriod Delay after deployment before proposals are accepted.
     */
    function initialize(
        string calldata _name,
        IVotes _token,
        uint48 _votingDelay,
        uint32 _votingPeriod,
        uint256 _proposalThreshold,
        uint256 _quorumNumerator,
        address _governanceCycleIncentivizer,
        uint256 _minQuorum,
        uint256 _bootstrapPeriod,
        uint256 _maxTreasurySpendRatio,
        uint256 _upgradeSupermajorityRatio
    ) external override initializer {
        __Governor_init(_name);
        __GovernorSettings_init(_votingDelay, _votingPeriod, _proposalThreshold);
        __GovernorCountingFractional_init();
        __GovernorStorage_init();
        __GovernorVotes_init(_token);
        __GovernorVotesQuorumFraction_init(_quorumNumerator);
        __MemecoinDaoGovernor_init(
            _governanceCycleIncentivizer,
            _minQuorum,
            _bootstrapPeriod,
            _maxTreasurySpendRatio,
            _upgradeSupermajorityRatio
        );
    }

    /// @notice Exposes how long a proposal waits before voting opens.
    /// @dev Delegates to the OpenZeppelin governor-settings module.
    /// @return Voting delay in governor clock units.
    function votingDelay() public view override(GovernorUpgradeable, GovernorSettingsUpgradeable) returns (uint256) {
        return super.votingDelay();
    }

    /// @notice Exposes how long voting remains open for each proposal.
    /// @dev Delegates to the OpenZeppelin governor-settings module.
    /// @return Voting period in governor clock units.
    function votingPeriod() public view override(GovernorUpgradeable, GovernorSettingsUpgradeable) returns (uint256) {
        return super.votingPeriod();
    }

    /// @notice Exposes the quorum required for a proposal snapshot at `timepoint`.
    /// @dev Delegates to the quorum-fraction extension configured during initialization. The governor clock is
    ///      delegated to the vote token (yield vault), so `timepoint` is a timestamp, not a block number.
    /// @param timepoint Snapshot timepoint (governor clock = vault timestamp) used for the quorum calculation.
    /// @return Required quorum amount.
    function quorum(uint256 timepoint)
        public
        view
        override(GovernorUpgradeable, GovernorVotesQuorumFractionUpgradeable)
        returns (uint256)
    {
        return Math.max(super.quorum(timepoint), memecoinDaoGovernorStorage._minQuorum);
    }

    /// @notice Exposes the minimum voting power required to create a proposal.
    /// @dev Delegates to the OpenZeppelin governor-settings module.
    /// @return Proposal threshold in vote units.
    function proposalThreshold()
        public
        view
        override(GovernorUpgradeable, GovernorSettingsUpgradeable)
        returns (uint256)
    {
        return super.proposalThreshold();
    }

    /// @notice Exposes the incentivizer contract paired with this governor.
    /// @dev The incentivizer tracks cycle votes and reward distribution for this DAO.
    /// @return Incentivizer contract address.
    function governanceCycleIncentivizer() external view override returns (address) {
        return address(memecoinDaoGovernorStorage._governanceCycleIncentivizer);
    }

    /// @notice Returns the absolute minimum quorum floor.
    /// @return Minimum quorum in vote units.
    function minQuorum() external view override returns (uint256) {
        return memecoinDaoGovernorStorage._minQuorum;
    }

    /// @notice Returns the timestamp when governance proposals become active.
    /// @return Start timestamp for governance.
    function governanceStartTime() external view override returns (uint256) {
        return memecoinDaoGovernorStorage._governanceStartTime;
    }

    /// @notice Returns the maximum treasury spend ratio allowed for one execution.
    /// @dev The ratio is expressed in basis points, using 10000 as the denominator for 100%.
    function maxTreasurySpendRatio() external view override returns (uint256) {
        return memecoinDaoGovernorStorage._maxTreasurySpendRatio;
    }

    /// @notice Returns the vote ratio required for proposals that target the Governor (self-call) or the paired
    ///         incentivizer.
    /// @dev The ratio is expressed in basis points with denominator 10000. It applies when any proposal target is this
    ///      Governor (a self-call) or the paired governance cycle incentivizer, and compares
    ///      `forVotes / (forVotes + againstVotes + abstainVotes)`.
    function upgradeSupermajorityRatio() external view returns (uint256) {
        return memecoinDaoGovernorStorage._upgradeSupermajorityRatio;
    }

    /// @notice Creates a new governance proposal for the caller.
    /// @dev `userUnfinalizedProposalId` stores the latest proposal id for each proposer. A normal proposal is
    ///      blocked while that stored proposal is not `Defeated` or `Succeeded`.
    /// @param targets The call targets for the proposal actions.
    /// @param values The ETH values for the proposal actions.
    /// @param calldatas The calldata payloads for the proposal actions.
    /// @param description The proposal description.
    /// @return proposalId The created proposal identifier.
    function propose(
        address[] memory targets,
        uint256[] memory values,
        bytes[] memory calldatas,
        string memory description
    ) public override returns (uint256) {
        require(block.timestamp >= memecoinDaoGovernorStorage._governanceStartTime, GovernanceNotStarted());

        // Restrict each address from submitting new proposals while it has unfinalized proposal
        uint256 unfinalizedProposalId = memecoinDaoGovernorStorage.userUnfinalizedProposalId[msg.sender];
        require(
            unfinalizedProposalId == 0 || state(unfinalizedProposalId) == ProposalState.Defeated
                || state(unfinalizedProposalId) == ProposalState.Succeeded,
            UserHasUnfinalizedProposal()
        );

        uint256 proposalId = super.propose(targets, values, calldatas, description);
        memecoinDaoGovernorStorage.userUnfinalizedProposalId[msg.sender] = proposalId;

        return proposalId;
    }

    /// @notice Runs a successful proposal and clears its proposer's outstanding-proposal marker.
    /// @dev Delegates execution to OpenZeppelin governor core, then compare-and-clears the marker so finalizing an
    ///      older proposal cannot clear a newer marker.
    /// @param targets The proposal action targets.
    /// @param values The ETH values for the proposal actions.
    /// @param calldatas The calldata payloads for the proposal actions.
    /// @param descriptionHash The hash of the proposal description.
    /// @return proposalId The executed proposal identifier.
    function execute(
        address[] memory targets,
        uint256[] memory values,
        bytes[] memory calldatas,
        bytes32 descriptionHash
    ) public payable override returns (uint256) {
        uint256 proposalId = super.execute(targets, values, calldatas, descriptionHash);

        _clearUnfinalizedProposalMarker(proposalId);

        return proposalId;
    }

    /// @dev Cancels a proposal through OpenZeppelin governor core, then compare-and-clears its proposer's marker so a
    ///      stale or out-of-order finalization cannot clear a newer marker.
    function _cancel(
        address[] memory targets,
        uint256[] memory values,
        bytes[] memory calldatas,
        bytes32 descriptionHash
    ) internal override returns (uint256) {
        uint256 proposalId = super._cancel(targets, values, calldatas, descriptionHash);

        _clearUnfinalizedProposalMarker(proposalId);

        return proposalId;
    }

    /**
     * @notice Receive treasury income on behalf of the DAO treasury.
     * @dev Pulls the tokens into the governor treasury, then records the income on the incentivizer ledger.
     * @param _token The token being supplied.
     * @param _amount The amount received.
     */
    function receiveTreasuryIncome(address _token, uint256 _amount) external override {
        IGovernanceCycleIncentivizer _governanceCycleIncentivizer =
        memecoinDaoGovernorStorage._governanceCycleIncentivizer;
        IERC20(_token).safeTransferFrom(msg.sender, address(this), _amount);
        _governanceCycleIncentivizer.recordTreasuryIncome(_token, _amount);
    }

    /**
     * @notice Confirms a treasury token registration during a standalone execution.
     * @dev The paired incentivizer calls this after it has registered the token. No registration state is stored here;
     * the non-nested execution context and one-operation count are the checks that allow confirmation only for a
     * standalone registration operation.
     */
    function recordTreasuryTokenRegistration(address) external override {
        if (msg.sender != address(memecoinDaoGovernorStorage._governanceCycleIncentivizer)) {
            revert UnauthorizedTreasuryTokenRegistration();
        }
        if (!memecoinDaoGovernorStorage._executionActive) revert RegistrationOutsideExecution();
        if (memecoinDaoGovernorStorage._executionOperationCount != 1) revert RegistrationMustBeStandalone();
    }

    /**
     * @notice Transfer treasury assets to another address through governance.
     * @dev Notifies the incentivizer before sending the tokens from the governor treasury. All treasury transfers must use this entrypoint.
     * @param _token Token being transferred.
     * @param _to Receiver address.
     * @param _amount Amount transferred.
     */
    function sendTreasuryAssets(address _token, address _to, uint256 _amount) external override onlyGovernance {
        IGovernanceCycleIncentivizer _governanceCycleIncentivizer =
        memecoinDaoGovernorStorage._governanceCycleIncentivizer;
        _governanceCycleIncentivizer.recordTreasuryAssetSpend(_token, _to, _amount);

        IERC20(_token).safeTransfer(_to, _amount);
    }

    /**
     * @notice Disburse reward assets from governor custody to a user.
     * @dev Only callable by the paired incentivizer. Reward accounting is handled in the incentivizer.
     * @param _token Reward token to transfer.
     * @param _to Reward recipient.
     * @param _amount Reward amount.
     */
    function disburseReward(address _token, address _to, uint256 _amount) external override {
        require(
            msg.sender == address(memecoinDaoGovernorStorage._governanceCycleIncentivizer), UnauthorizedRewardPayout()
        );

        IERC20(_token).safeTransfer(_to, _amount);
    }

    /// @dev Rejects nested execution and records the operation count so registration confirmation can be limited to
    ///      a one-operation execution. The registered token list and this Governor's balances are snapshotted before
    ///      operations run. Afterward, only tokens with `pre > 0` and `post < pre` are checked: `spent = pre - post`
    ///      and `limit = pre * maxTreasurySpendRatio / 10000`.
    function _executeOperations(
        uint256 proposalId,
        address[] memory targets,
        uint256[] memory values,
        bytes[] memory calldatas,
        bytes32 descriptionHash
    ) internal override {
        if (memecoinDaoGovernorStorage._executionActive) revert NestedExecution();

        memecoinDaoGovernorStorage._executionActive = true;
        uint256 targetsLength = targets.length;
        memecoinDaoGovernorStorage._executionOperationCount = targetsLength;

        // Layer 4: a governor self-call OR an incentivizer target both require the upgrade supermajority. The
        // incentivizer is gated because a swapped implementation can move governor treasury via disburseReward,
        // bypassing the per-execution treasury cap that only runs inside this function.
        address incentivizer = address(memecoinDaoGovernorStorage._governanceCycleIncentivizer);
        bool requiresUpgradeSupermajority = false;
        for (uint256 i = 0; i < targetsLength; ++i) {
            if (targets[i] == address(this) || targets[i] == incentivizer) {
                requiresUpgradeSupermajority = true;
                break;
            }
        }
        if (requiresUpgradeSupermajority) {
            (uint256 againstVotes, uint256 forVotes, uint256 abstainVotes) = proposalVotes(proposalId);
            uint256 totalVotes = forVotes + againstVotes + abstainVotes;
            require(
                forVotes * 10000 >= totalVotes * memecoinDaoGovernorStorage._upgradeSupermajorityRatio,
                UpgradeSupermajorityRequired(
                    forVotes, totalVotes, memecoinDaoGovernorStorage._upgradeSupermajorityRatio
                )
            );
        }

        // Snapshot registered treasury balances before any proposal action can move them.
        (,,, address[] memory treasuryTokens,) = memecoinDaoGovernorStorage._governanceCycleIncentivizer.metaData();
        uint256 treasuryTokenLength = treasuryTokens.length;
        uint256[] memory preBalances = new uint256[](treasuryTokenLength);
        for (uint256 i = 0; i < treasuryTokenLength; ++i) {
            preBalances[i] = IERC20(treasuryTokens[i]).balanceOf(address(this));
        }

        super._executeOperations(proposalId, targets, values, calldatas, descriptionHash);

        // Check balance diff for each treasury token
        for (uint256 i = 0; i < treasuryTokenLength; ++i) {
            if (preBalances[i] == 0) continue;
            uint256 postBalance = IERC20(treasuryTokens[i]).balanceOf(address(this));
            if (postBalance >= preBalances[i]) continue;
            uint256 spent = preBalances[i] - postBalance;
            uint256 limit = preBalances[i] * memecoinDaoGovernorStorage._maxTreasurySpendRatio / 10000;
            require(spent <= limit, TreasurySpendExceedsLimit(treasuryTokens[i], spent, limit));
        }

        memecoinDaoGovernorStorage._executionActive = false;
        memecoinDaoGovernorStorage._executionOperationCount = 0;
    }

    function _propose(
        address[] memory targets,
        uint256[] memory values,
        bytes[] memory calldatas,
        string memory description,
        address proposer
    ) internal override(GovernorUpgradeable, GovernorStorageUpgradeable) returns (uint256) {
        return super._propose(targets, values, calldatas, description, proposer);
    }

    function _castVote(uint256 proposalId, address account, uint8 support, string memory reason, bytes memory params)
        internal
        override
        returns (uint256)
    {
        uint256 votes = super._castVote(proposalId, account, support, reason, params);
        memecoinDaoGovernorStorage._governanceCycleIncentivizer.accumCycleVotes(account, votes);
        return votes;
    }

    /**
     * @dev Allowing upgrades to the implementation contract only through governance proposals.
     */
    function _authorizeUpgrade(address newImplementation) internal override onlyGovernance {}

    /// @dev Clear the marker only while it still identifies this proposal; newer proposals remain protected.
    function _clearUnfinalizedProposalMarker(uint256 proposalId) private {
        address proposer = proposalProposer(proposalId);
        if (memecoinDaoGovernorStorage.userUnfinalizedProposalId[proposer] == proposalId) {
            memecoinDaoGovernorStorage.userUnfinalizedProposalId[proposer] = 0;
        }
    }
}
