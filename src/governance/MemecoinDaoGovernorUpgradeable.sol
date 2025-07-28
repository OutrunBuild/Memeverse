// SPDX-License-Identifier: GPL-3.0
// Compatible with OpenZeppelin Contracts ^5.0.0
pragma solidity ^0.8.28;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { Initializable } from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import { UUPSUpgradeable } from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import { GovernorUpgradeable } from "@openzeppelin/contracts-upgradeable/governance/GovernorUpgradeable.sol";
import { GovernorVotesUpgradeable } from "@openzeppelin/contracts-upgradeable/governance/extensions/GovernorVotesUpgradeable.sol";
import { GovernorStorageUpgradeable } from "@openzeppelin/contracts-upgradeable/governance/extensions/GovernorStorageUpgradeable.sol";
import { GovernorSettingsUpgradeable } from "@openzeppelin/contracts-upgradeable/governance/extensions/GovernorSettingsUpgradeable.sol";
import { GovernorCountingFractionalUpgradeable } from "@openzeppelin/contracts-upgradeable/governance/extensions/GovernorCountingFractionalUpgradeable.sol";
import { GovernorVotesQuorumFractionUpgradeable } from "@openzeppelin/contracts-upgradeable/governance/extensions/GovernorVotesQuorumFractionUpgradeable.sol";

import { IVotes, IMemecoinDaoGovernor, IGovernanceCycleIncentivizer } from "./interfaces/IMemecoinDaoGovernor.sol";

/** 
 * @title Memecoin DAO Governor
 * @notice This contract is a modified version of the GovernorUpgradeable contract from OpenZeppelin.   
 * @dev It is used to manage the DAO of the Memecoin project, also as Memecoin DAO Treasury.
 */
contract MemecoinDaoGovernorUpgradeable is 
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
    using SafeERC20 for IERC20;

    // keccak256(abi.encode(uint256(keccak256("outrun.storage.MemecoinDaoGovernor")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant MemecoinDaoGovernorStorageLocation = 0x173bbd0db440ff8dcb0efb05aced4279e21e45a07b4974973a371552ef840a00;

    function _getMemecoinDaoGovernorStorage() private pure returns (MemecoinDaoGovernorStorage storage $) {
        assembly {
            $.slot := MemecoinDaoGovernorStorageLocation
        }
    }

    function __MemecoinDaoGovernor_init(address _governanceCycleIncentivizer) internal onlyInitializing {
        MemecoinDaoGovernorStorage storage $ = _getMemecoinDaoGovernorStorage();
        $._governanceCycleIncentivizer = IGovernanceCycleIncentivizer(_governanceCycleIncentivizer);
    }

    constructor() {
        _disableInitializers();
    }

    /**
     * @notice Initialize the governor.
     * @param _name - The name of the governor.
     * @param _token - The vote token of the governor.
     * @param _votingDelay - The voting delay.
     * @param _votingPeriod - The voting period.
     * @param _proposalThreshold - The proposal threshold.
     * @param _quorumNumerator - The quorum numerator.
     * @param _governanceCycleIncentivizer - The governanceCycleIncentivizer.
     */
    function initialize(
        string memory _name, 
        IVotes _token,
        uint48 _votingDelay,
        uint32 _votingPeriod,
        uint256 _proposalThreshold,
        uint256 _quorumNumerator,
        address _governanceCycleIncentivizer
    ) external override initializer {
        __Governor_init(_name);
        __GovernorSettings_init(
            _votingDelay,
            _votingPeriod,
            _proposalThreshold
        );
        __GovernorCountingFractional_init();
        __GovernorStorage_init();
        __GovernorVotes_init(_token);
        __GovernorVotesQuorumFraction_init(_quorumNumerator);
        __MemecoinDaoGovernor_init(_governanceCycleIncentivizer);
        __UUPSUpgradeable_init();
    }

    function votingDelay()
        public
        view
        override(GovernorUpgradeable, GovernorSettingsUpgradeable)
        returns (uint256)
    {
        return super.votingDelay();
    }

    function votingPeriod()
        public
        view
        override(GovernorUpgradeable, GovernorSettingsUpgradeable)
        returns (uint256)
    {
        return super.votingPeriod();
    }

    function quorum(uint256 blockNumber)
        public
        view
        override(GovernorUpgradeable, GovernorVotesQuorumFractionUpgradeable)
        returns (uint256)
    {
        return super.quorum(blockNumber);
    }

    function proposalThreshold()
        public
        view
        override(GovernorUpgradeable, GovernorSettingsUpgradeable)
        returns (uint256)
    {
        return super.proposalThreshold();
    }

    function governanceCycleIncentivizer() external view override returns (address) {
        return address(_getMemecoinDaoGovernorStorage()._governanceCycleIncentivizer);
    }

    function propose(
        address[] memory targets,
        uint256[] memory values,
        bytes[] memory calldatas,
        string memory description
    ) public override returns (uint256) {
        // Restrict each address from submitting new proposals while it has unfinalized proposal
        MemecoinDaoGovernorStorage storage $ = _getMemecoinDaoGovernorStorage();
        uint256 unfinalizedProposalId = $.userUnfinalizedProposalId[msg.sender];
        require(unfinalizedProposalId == 0 || state(unfinalizedProposalId) == ProposalState.Defeated, UserHasUnfinalizedProposal());

        uint256 proposalId = super.propose(targets, values, calldatas, description);
        $.userUnfinalizedProposalId[msg.sender] = proposalId;

        return proposalId;
    }

    function execute(
        address[] memory targets,
        uint256[] memory values,
        bytes[] memory calldatas,
        bytes32 descriptionHash
    ) public payable override returns (uint256) {
        uint256 proposalId = super.execute(targets, values, calldatas, descriptionHash);

        _getMemecoinDaoGovernorStorage().userUnfinalizedProposalId[proposalProposer(proposalId)] = 0;

        return proposalId;
    }

    function _cancel(
        address[] memory targets,
        uint256[] memory values,
        bytes[] memory calldatas,
        bytes32 descriptionHash
    ) internal override returns (uint256) {
        uint256 proposalId = super._cancel(targets, values, calldatas, descriptionHash);

        _getMemecoinDaoGovernorStorage().userUnfinalizedProposalId[proposalProposer(proposalId)] = 0;

        return proposalId;
    }

    /**
     * @dev Receive treasury income
     * @param _token - The token address
     * @param _amount - The amount
     */
    function receiveTreasuryIncome(address _token, uint256 _amount) external override {
        IGovernanceCycleIncentivizer _governanceCycleIncentivizer = _getMemecoinDaoGovernorStorage()._governanceCycleIncentivizer;
        _governanceCycleIncentivizer.receiveTreasuryIncome(_token, _amount);

        IERC20(_token).safeTransferFrom(msg.sender, address(this), _amount);
    }

    /**
     * @dev Transfer treasury assets to another address
     * @param _token - The token address
     * @param _to - The receiver address
     * @param _amount - The amount to transfer
     * @notice All actions to transfer assets from the DAO treasury MUST call this function
     */
    function sendTreasuryAssets(address _token, address _to, uint256 _amount) external override onlyGovernance {
        IGovernanceCycleIncentivizer _governanceCycleIncentivizer = _getMemecoinDaoGovernorStorage()._governanceCycleIncentivizer;
        _governanceCycleIncentivizer.sendTreasuryAssets(_token, _to, _amount);

        IERC20(_token).safeTransfer(_to, _amount);
    }

    function _propose(address[] memory targets, uint256[] memory values, bytes[] memory calldatas, string memory description, address proposer)
        internal
        override(GovernorUpgradeable, GovernorStorageUpgradeable)
        returns (uint256)
    {
        return super._propose(targets, values, calldatas, description, proposer);
    }

    function _castVote(
        uint256 proposalId,
        address account,
        uint8 support,
        string memory reason,
        bytes memory params
    ) internal override returns (uint256) {
        uint256 votes = super._castVote(proposalId, account, support, reason, params);
        _getMemecoinDaoGovernorStorage()._governanceCycleIncentivizer.accumCycleVotes(account, votes);
        return votes;
    }

    /**
     * @dev Allowing upgrades to the implementation contract only through governance proposals.
     */
    function _authorizeUpgrade(address newImplementation) internal override onlyGovernance {}
}
