// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.6;

import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";

contract DAO is ReentrancyGuard,AccessControl{
    bytes32 private immutable CONTRIBUTOR_ROLE=keccak256("CONTRIBUTOR");
    bytes32 private immutable STAKEHOLDER_ROLE=keccak256("STAKEHOLDER");

    uint256 immutable MIN_STAKEHOLDER_CONTRIBUTION=1 ether;
    uint32 immutable MIN_VOTE_DURATION= 10 minutes;

    uint32 totalProposals; //int keeps track of total no of prop in the dao
    uint256 public daoBalance; //total balance in the dao

    //all the raised prop are stored in thsi mapping
    //point to a particular prop by its prop id
    mapping(uint256 => ProposalStruct) private raisedProposals;
    
    //mapping of votes given by individual stakeholder to diff props

    mapping(address=> uint256[]) private stakeholderVotes;
   
   //contains all the voting info abt a particular prop
   //referenced by prop id
    mapping(uint256=> VotedStruct[]) private votedOn;

    //total contribution for each contributor
    mapping(address => uint256) private contributors;
    //total contribution for each stakeholder
    mapping(address => uint256) private stakeholders;

    struct ProposalStruct{
        uint256 id;
        uint256 amount;
        uint256 duration;
        uint256 upvotes;
        uint256 downvotes;
        string title;
        string description;
        bool passed;
        bool paid;
        address payable beneficiary;
        address proposer;
        address executor;
    }

    //holds info abt an individual voter
    struct VotedStruct{
        address voter;
        uint256 timestamp;
        bool chosen;
    }

    //universal event for every action 
    event Action(
        address indexed initiator,
        bytes32 role,
        string message,
        address indexed beneficiary,
        uint256 amount 
    );

    modifier stakeholderOnly(string memory message){
        require(hasRole(STAKEHOLDER_ROLE,msg.sender),message);
        _;
    }

    modifier contributorOnly(string memory message){
        require(hasRole(CONTRIBUTOR_ROLE,msg.sender),message);
        _;
    }

    function createProposal(
        string memory title,
        string memory description,
        address beneficiary,
        uint amount
    ) external stakeholderOnly("proposal creation allowed for the stakeholders only")
    {
        uint32 proposalId=totalProposals++;
        ProposalStruct storage proposal=raisedProposals[proposalId];

        proposal.id=proposalId;
        proposal.proposer=payable(msg.sender);
        proposal.title=title;
        proposal.description=description;
        proposal.beneficiary=payable(beneficiary);
        proposal.amount=amount;
        proposal.duration=block.timestamp+MIN_VOTE_DURATION;

        emit Action(
            msg.sender,
            STAKEHOLDER_ROLE,
            "PROPOSAL RAISED",
            beneficiary,
            amount
        );
    }


    //all these checks are handled before the actual voting by a proposer
    function handleVoting(ProposalStruct storage proposal) internal{
        //first thing is to check if this prop passed already
        //or if the duration is active or still open
        //then next thing is to say this this proposal has been passed
        //by updating the boolean 
        //this checks if the proposal has been passed
        //or the voting time has been elapsed
        if(
            proposal.passed ||
            proposal.duration<=block.timestamp
        ){
            proposal.passed=true;
            revert("proposal duration expired");
        }

        //a list of all the votes given by a proposer 
        //for diff proposasls
        uint256[] memory tempVotes=stakeholderVotes[msg.sender];
        //check if a proposer has already voted on the proposal 
        //by using prop id for reference
        //if double voting found for this particular prop then revert
        for(uint256 votes=0;votes<tempVotes.length;votes++){
            if(proposal.id==tempVotes[votes]){
                revert("Double voting not allowed");
            }
        }
    }


    //voting is based on the votedstruct struct for individual voters
    function Vote(uint256 proposalId,bool chosen) public stakeholderOnly("Unauthorized access: Stakeholders only permitted")
    returns (VotedStruct memory){

        //create a new prop object in the storage
        ProposalStruct storage proposal=raisedProposals[proposalId];
        //perform the voting procedure
        handleVoting(proposal);

        //if this particular voter as voted for particular prop,
        //increment the upvotes for this particular proposal by 1
        //otherwise downvote is incremented by 1
        if(chosen) proposal.upvotes++;
        else proposal.downvotes++;


        //push the individual stakeholder(msg.sender) vote for this corresponding proposal
        //referenced by the proposal id 
        stakeholderVotes[msg.sender].push(proposal.id);

        //push this particular prop id in the Voted on mapping
        //push this voter as one of the entities that has voted
        //for this particular proposal referenced by prop id
        //contains all the details for all the voters for a particular prop id
        votedOn[proposal.id].push(
            VotedStruct(
                msg.sender,
                block.timestamp,
                chosen
            )
        );
        emit Action(
            msg.sender,
            STAKEHOLDER_ROLE,
            "PROPOSAL VOTE",
            proposal.beneficiary,
            proposal.amount
        );
        return VotedStruct(
            msg.sender,
            block.timestamp,
            chosen
        );
    }

    //pay a particular amt to a particular address
    //its an internal function which means it cant be seen by others
    function payTo(address to, uint256 amount) internal returns (bool) {
        
        (bool success,) = payable(to).call{value: amount}("");
        require(success, "Payment failed");
        return true;
    }



    //function responsible for DAO fund management to recepient
    //also check whether this function is called by a malicious attacker or not
    //since it has direct access to DAO balance
    function payBeneficiary(uint256 proposalId)
        public
        stakeholderOnly("Unauthorized: Stakeholders only")
        nonReentrant()
        returns (uint256)
    {
        //retrieve the proposal from storage by referencing its id
        //and place it here in the function by creating the storage object here
        ProposalStruct storage proposal = raisedProposals[proposalId];
        require(daoBalance >= proposal.amount, "Insufficient fund");

        if (proposal.paid) revert("Payment sent before");

        if (proposal.upvotes <= proposal.downvotes)
            revert("Insufficient votes");


        proposal.paid = true;
        proposal.executor = msg.sender;
        daoBalance -= proposal.amount;

        payTo(proposal.beneficiary, proposal.amount);

        emit Action(
            msg.sender,
            STAKEHOLDER_ROLE,
            "PAYMENT TRANSFERED",
            proposal.beneficiary,
            proposal.amount
        );

        return daoBalance;
    }


    //receive money from people from dao 
    //document in our dao that this person has contributed to the dao
    function contribute() payable public {
        require(msg.value > 0 ether, "Contributing zero is not allowed.");
        if (!hasRole(STAKEHOLDER_ROLE, msg.sender)) {

            //grab the total contributions by this contributor
            //see how much he as already contributed to this platform
            //contributors[msg.sender] returns total contribution by a contributor
            uint256 totalContribution =
                contributors[msg.sender] + msg.value;//add total contri with current amt

            if (totalContribution >= MIN_STAKEHOLDER_CONTRIBUTION) {
                //assign the total contribution to this stakeholders account
                stakeholders[msg.sender] = totalContribution;
                //_grantRole comes from AccessControl.sol
                //if total contribution > 1 eth, person is both stakeholder and contributor
                //otherwise he's just contributor
                _grantRole(STAKEHOLDER_ROLE, msg.sender);
             
            }
             //add only amt for contributor
                contributors[msg.sender] += msg.value;
                _grantRole(CONTRIBUTOR_ROLE,msg.sender);
        } else {
            contributors[msg.sender] += msg.value;
            stakeholders[msg.sender] += msg.value;
        }
        //increment dao balance by this new contribution
        daoBalance += msg.value;

        emit Action(
            msg.sender,
            STAKEHOLDER_ROLE,
            "CONTRIBUTION RECEIVED",
            address(this),
            msg.value
        );   
    }

    function getProposals()
        public
        view
        returns (ProposalStruct[] memory props)
    {
        props = new ProposalStruct[](totalProposals);

        for (uint256 i = 0; i < totalProposals; i++) {
            props[i] = raisedProposals[i];
        }
    }

    //all the functions below act as contract interface and can only be called by an EOA
    //and not internally by other contract functions

    function getProposal(uint256 proposalId)
        external
        view
        returns (ProposalStruct memory)
    {
        return raisedProposals[proposalId];
    }
    
    function getVotesOf(uint256 proposalId)
        external
        view
        returns (VotedStruct[] memory)
    {
        return votedOn[proposalId];
    }

    function getStakeholderVotes()
       external
        view
        stakeholderOnly("Unauthorized: not a stakeholder")
        returns (uint256[] memory)
    {
        return stakeholderVotes[msg.sender];
    }

    function getStakeholderBalance()
        external
        view
        stakeholderOnly("Unauthorized: not a stakeholder")
        returns (uint256)
    {
        return stakeholders[msg.sender];
    }

    function isStakeholder()external view returns (bool) {
        return stakeholders[msg.sender] > 0;
    }

    function getContributorBalance()
        external
        view
        contributorOnly("Denied: User is not a contributor")
        returns (uint256)
    {
        return contributors[msg.sender];
    }

    function isContributor()external view returns (bool) {
        return contributors[msg.sender] > 0;
    }

    function getBalance() external view returns (uint256) {
        return contributors[msg.sender];
    }

}
