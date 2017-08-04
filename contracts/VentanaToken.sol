/*
file:   VentanaToken.sol
ver:    0.0.7
updated:4-Aug-2017
author: Darryl Morris
email:  o0ragman0o AT gmail.com
(c) Darryl Morris 2017

A collated contract set for a token sale specific to the requirments of
Veredictum's Ventana token product.

This software is distributed in the hope that it will be useful,
but WITHOUT ANY WARRANTY; without even the implied warranty of
MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  
See MIT Licence for further details.
<https://opensource.org/licenses/MIT>.

Release Notes
-------------
0.0.7
* added Notifier interface and VeredictumTest contract
* added 'address public veredictum'
* added 'function changeVeredictum(address _addr) public returns (bool);'
* transfer and transferFrom now notify the Veridictum contract if it recieves
tokens
* transfer and transferFrom modified as 'preventReentry' due to external call.
*/


pragma solidity ^0.4.13;

/*-----------------------------------------------------------------------------\

 Ventana token sale configuration

\*----------------------------------------------------------------------------*/

// Contains token sale parameters
contract VentanaTokenConfig
{
    // ERC20 trade symbol
    string public           symbol          = "VNT";

    // Owner has power to abort, discount addresses, sweep successful funds,
    // change owner, sweep alien tokens.
    address public          owner           = msg.sender;
    
    // Fund wallet should also be audited prior to deployment
    // NOTE: Must be checksummed address!
    address public constant FUND_WALLET     = 0xCA35b7d915458EF540aDe6068dFe2F44E8fa733c;
    
    // Tokens awarded per USD contributed
    uint public constant    TOKENS_PER_USD  = 3;

    // Ether market price in USD
    uint public constant    USD_PER_ETH     = 200;
    
    // Minimum and maximum target in USD
    uint public constant    MIN_USD_FUND    = 2000000;  // $2m
    uint public constant    MAX_USD_FUND    = 20000000; // $20m
    
    // Non-KYC contribution limit in USD
    uint public constant    KYC_USD_LMT     = 10000;
    
    // Prefunding period to allow for verification, publication and
    // discounting and contributions for selected addresses
    uint public constant    PREFUND_PERIOD  = 1 minutes; //7 days;
    
    // Period for fundraising
    uint public constant    FUNDING_PERIOD  = 2 minutes; //21 days;
}


library SafeMath
{
    // a add to b
    function add(uint a, uint b) internal returns (uint c) {
        c = a + b;
        assert(c >= a);
    }
    
    // a subtract b
    function sub(uint a, uint b) internal returns (uint c) {
        c = a - b;
        assert(c <= a);
    }
    
    // a multiplied by b
    function mul(uint a, uint b) internal returns (uint c) {
        c = a * b;
        assert(a == 0 || c / a == b);
    }
    
    // a divided by b
    function div(uint a, uint b) internal returns (uint c) {
        c = a / b;
        // No assert required as no overflows are posible.
    }
}


contract ReentryProtected
{
    // The reentry protection state mutex.
    bool __reMutex;

    // Sets and resets mutex in order to block functin reentry
    modifier preventReentry() {
        require(!__reMutex);
        __reMutex = true;
        _;
        delete __reMutex;
    }

    // Blocks function entry if mutex is set
    modifier noReentry() {
        require(!__reMutex);
        _;
    }
}

contract ERC20Token
{
    using SafeMath for uint;

/* Constants */

    // none
    
/* State variable */

    /// @return The Total supply of tokens
    uint public totalSupply;
    
    /// @return Token symbol
    string public symbol;
    
    // Token ownership mapping
    mapping (address => uint) balances;
    
    // Allowances mapping
    mapping (address => mapping (address => uint)) allowed;

/* Events */

    // Triggered when tokens are transferred.
    event Transfer(
        address indexed _from,
        address indexed _to,
        uint256 _amount);

    // Triggered whenever approve(address _spender, uint256 _amount) is called.
    event Approval(
        address indexed _owner,
        address indexed _spender,
        uint256 _amount);

/* Modifiers */

    // none
    
/* Functions */

    // Using an explicit getter allows for function overloading    
    function balanceOf(address _addr)
        public
        constant
        returns (uint)
    {
        return balances[_addr];
    }
    
    // Using an explicit getter allows for function overloading    
    function allowance(address _owner, address _spender)
        public
        constant
        returns (uint)
    {
        return allowed[_owner][_spender];
    }

    // Send _value amount of tokens to address _to
    function transfer(address _to, uint256 _amount)
        public
        returns (bool)
    {
        return xfer(msg.sender, _to, _amount);
    }

    // Send _value amount of tokens from address _from to address _to
    function transferFrom(address _from, address _to, uint256 _amount)
        public
        returns (bool)
    {
        require(_amount <= allowed[_from][msg.sender]);
        
        allowed[_from][msg.sender] = allowed[_from][msg.sender].sub(_amount);
        return xfer(_from, _to, _amount);
    }

    // Process a transfer internally.
    function xfer(address _from, address _to, uint _amount)
        internal
        returns (bool)
    {
        require(_amount <= balances[_from]);
        
        balances[_from] = balances[_from].sub(_amount);
        balances[_to]   = balances[_to].add(_amount);
        
        Transfer(_from, _to, _amount);
        return true;
    }

    // Approves a third-party spender
    function approve(address _spender, uint256 _amount)
        public
        returns (bool)
    {
        allowed[msg.sender][_spender] = _amount;
        Approval(msg.sender, _spender, _amount);
        return true;
    }
}



/*-----------------------------------------------------------------------------\

Conditional Entry Table (functions must throw on F conditions)

renetry prevention on all public mutating functions
Reentry mutex set in moveFundsToWallet(), refund()

function            <PREFUND_PERIOD <END_DATE  fundFailed fundSucceeded icoSucceeded
------------------------------------------------------------------------------------
()                          KYC         T           F           F           F
proxyPurchase()             KYC         T           F           F           F
abort()                     T           T           T           T           F
moveFundsToWallet()         F           F           F           T           T
refund(address _addr)       F           F           T           F           F
transfer()                  F           F           F           F           T
transferFrom()              F           F           F           F           T
approve()                   F           F           F           F           T   
destroy()                   F           F      !__abortFuse     F           F
changeOwner()               T           T           T           T           T
acceptOwnership()           T           T           T           T           T
changeVeredictum()          T           T           T           T           T
transferAnyERC20Tokens()    T           T           T           T           T
-----------------------------------------------------------------------------------

\*----------------------------------------------------------------------------*/

contract VentanaTokenAbstract
{
    event KYCAddress(address indexed _addr, bool indexed _kyc);
    event Refunded(address indexed _addr, uint indexed _value);
    event ChangedOwner(address indexed _from, address indexed _to);
    event ChangeOwnerTo(address indexed _to);
    event FundsTransferred(address indexed _wallet, uint indexed _value);

    // This fuse blows upon calling abort() which forces a fail state
    bool __abortFuse = true;
    
    // Set to true after the fund is swept to the fund wallet, allows token
    // transfers and prevents abort()
    bool public icoSuccessful;

    // Token conversion factors are calculated with decimal places at parity with ether
    uint8 public constant decimals = 18;

    // An address authorised to take ownership
    address public newOwner;
    
    // The Veredictum smart contract address
    address public veredictum;
    
    // Total ether raised during funding
    uint public etherRaised;
    
    // Preauthorized tranch discount addresses
    // holder => discount
    mapping (address => bool) public kycAddresses;
    
    // Record of ether paid per address
    mapping (address => uint) public etherContributed;

    // Return `true` if MIN_FUNDS were raised
    function fundSucceeded() public constant returns (bool);
    
    // Return `true` if MIN_FUNDS were not raised before END_DATE
    function fundFailed() public constant returns (bool);

    // Returns USD raised for set ETH/USD rate
    function usdRaised() public constant returns (uint);

    // Returns an amount in eth equivilent to USD at the set rate
    function usdToEth(uint) public constant returns(uint);
    
    // Returns the USD value of ether at the set USD/ETH rate
    function ethToUsd(uint _wei) public constant returns (uint);

    // Returns token/ether conversion given ether value and address. 
    function ethToTokens(uint _eth)
        public constant returns (uint);

    // Processes a token purchase for a given address
    function proxyPurchase(address _addr) payable returns (bool);

    // Owner can move funds of successful fund to fundWallet 
    function moveFundsToWallet() public returns (bool);
    
    // Registers a discounted address
    function addKycAddress(address _addr, bool _kyc)
        public returns (bool);

    // Refund on failed or aborted sale 
    function refund(address _addr) public returns (bool);

    // To cancel token sale prior to START_DATE
    function abort() public returns (bool);
    
    // Change the Veredictum backend contract address
    function changeVeredictum(address _addr) public returns (bool);
    
    // For owner to salvage tokens sent to contract
    function transferAnyERC20Token(address tokenAddress, uint amount)
        returns (bool);
}


/*-----------------------------------------------------------------------------\

 Ventana token implimentation

\*----------------------------------------------------------------------------*/

contract VentanaToken is 
    ReentryProtected,
    ERC20Token,
    VentanaTokenAbstract,
    VentanaTokenConfig
{
    using SafeMath for uint;

//
// Constants
//

    // USD to ether conversion factors calculated from `VentanaTokenConfig` constants 
    uint public constant TOKENS_PER_ETH = TOKENS_PER_USD * USD_PER_ETH;
    uint public constant MIN_ETH_FUND   = 1 ether * MIN_USD_FUND / USD_PER_ETH;
    uint public constant MAX_ETH_FUND   = 1 ether * MAX_USD_FUND / USD_PER_ETH;
    uint public constant KYC_ETH_LMT    = 1 ether * KYC_USD_LMT  / USD_PER_ETH;

    // General funding opens LEAD_IN_PERIOD after deployment (timestamps can't be constant)
    uint public FUND_DATE = now + PREFUND_PERIOD;
    uint public END_DATE  = FUND_DATE + FUNDING_PERIOD;

//
// Modifiers
//

    modifier onlyOwner {
        require(msg.sender == owner);
        _;
    }

//
// Functions
//

    // Constructor
    function VentanaToken()
    {
        // ICO parameters are set in VentanaTSConfig
        // Invalid configuration catching here
        require(bytes(symbol).length > 0);
        require(owner != 0x0);
        require(FUND_WALLET != 0x0);
        require(TOKENS_PER_USD > 0);
        require(USD_PER_ETH > 0);
        require(MIN_USD_FUND > 0);
        require(MAX_USD_FUND > MIN_USD_FUND);
        require(PREFUND_PERIOD > 0);
        require(FUNDING_PERIOD > 0);
    }
    
    // Default function
    function () payable
    {
        // Pass through to purchasing function. Will throw on failed or
        // successful ICO
        proxyPurchase(msg.sender);
    }

//
// Getters
//

    // ICO fails if aborted or minimum funds are not raised by the end date
    function fundFailed() public constant returns (bool)
    {
        return !__abortFuse
            || (now > END_DATE && etherRaised < MIN_ETH_FUND);
    }
    
    // Funding succeeds if not aborted, minimum funds are raised before end date
    function fundSucceeded() public constant returns (bool)
    {
        return !fundFailed()
            && now > END_DATE;
    }

    // Returns the USD value of ether at the set USD/ETH rate
    function ethToUsd(uint _wei) public constant returns (uint)
    {
        return USD_PER_ETH.mul(_wei).div(1 ether);
    }
    
    // Returns the ether value of USD at the set USD/ETH rate
    function usdToEth(uint _usd) public constant returns (uint)
    {
        return (_usd * 1 ether).div(USD_PER_ETH);
    }
    
    // Returns the USD value of ether raised at the set USD/ETH rate
    function usdRaised() public constant returns (uint)
    {
        return ethToUsd(etherRaised);
    }
    
    // Returns the number of tokens for given amount of ether for an address 
    function ethToTokens(uint _wei) public constant returns (uint)
    {
        uint usd = ethToUsd(_wei);
        
        // Percent bonus funding tiers for USD funding
        uint bonus =
            usd >= 2000000 ? 35 :
            usd >= 500000  ? 30 :
            usd >= 100000  ? 20 :
            usd >= 25000   ? 15 :
            usd >= 10000   ? 10 :
            usd >= 5000    ? 5  :
                             0;  
        
        return _wei.mul(TOKENS_PER_ETH).mul(bonus + 100).div(100);
    }

//
// ICO functions
//

    // The fundraising can be aborted any time before funds are swept to the
    // fundWallet.
    // This will force a fail state and allow refunds to be collected.
    function abort()
        public
        noReentry
        onlyOwner
        returns (bool)
    {
        require(!icoSuccessful);
        delete __abortFuse;
        return true;
    }
    
    // General addresses can purchase tokens during funding
    function proxyPurchase(address _addr)
        payable
        noReentry
        returns (bool)
    {
        require(!fundFailed());
        require(!fundSucceeded());
        require(msg.value > 0);
        
        // Non-KYC'ed funders can only contribute up to $10000 after prefund period
        if(!kycAddresses[_addr])
        {
            require(now > FUND_DATE);
            require((msg.value + etherContributed[_addr]) <= KYC_ETH_LMT);
        }

        // Base tokens
        uint tokens = ethToTokens(msg.value);
        
        // Update totalSupply
        totalSupply = totalSupply.add(tokens);
        
        // Update holder tokens and payments
        balances[_addr] = balances[_addr].add(tokens);
        etherContributed[_addr] = etherContributed[_addr].add(msg.value);
        
        // Update funds raised
        etherRaised = etherRaised.add(msg.value);
        
        // Bail if this pushes the fund over the USD cap or Token cap
        require(etherRaised <= MAX_ETH_FUND);

        // Indicate token creation by transferring from 0x0 address
        Transfer(0x0, _addr, tokens);
        return true;
    }
    
    // Owner can KYC (or revoke) addresses until close of funding
    function addKycAddress(address _addr, bool _kyc)
        public
        noReentry
        onlyOwner
        returns (bool)
    {
        require(!fundFailed());

        kycAddresses[_addr] = _kyc;
        KYCAddress(_addr, _kyc);
        return true;
    }
    
    // Owner can sweep a successful funding to the fundWallet
    // Contract can be aborted up until this action.
    function moveFundsToWallet()
        public
        onlyOwner
        preventReentry()
        returns (bool)
    {
        require(fundSucceeded());

        icoSuccessful = true;
        FundsTransferred(FUND_WALLET, this.balance);
        FUND_WALLET.transfer(this.balance);
        return true;
    }
    
    // Refunds can be claimed from a failed ICO
    function refund(address _addr)
        public
        preventReentry()
        returns (bool)
    {
        require(fundFailed());
        
        uint value = etherContributed[_addr];
        
        totalSupply = totalSupply.sub(balances[_addr]);
        
        // garbage collect
        delete etherContributed[_addr];
        delete balances[_addr];
        delete kycAddresses[_addr];
        
        Refunded(_addr, value);
        if (value > 0) {
            _addr.transfer(value);
        }
        return true;
    }

//
// ERC20 overloaded functions
//

    function transfer(address _to, uint _amount)
        public
        preventReentry
        returns (bool)
    {
        // ICO must be successful
        require(icoSuccessful);
        super.transfer(_to, _amount);
        if (_to == veredictum)
            // Notify the Veredictum contract it has been sent tokens
            require(Notify(veredictum).notify(msg.sender, _amount));
        return true;
    }

    function transferFrom(address _from, address _to, uint _amount)
        public
        preventReentry
        returns (bool)
    {
        // ICO must be successful
        require(icoSuccessful);
        super.transferFrom(_from, _to, _amount);
        if (_to == veredictum)
            // Notify the Veredictum contract it has been sent tokens
            require(Notify(veredictum).notify(msg.sender, _amount));
        return true;
    }
    
    function approve(address _spender, uint _amount)
        public
        noReentry
        returns (bool)
    {
        // ICO must be successful
        require(icoSuccessful);
        super.approve(_spender, _amount);
        return true;
    }

//
// Contract managment functions
//

    // To initiate an ownership change
    function changeOwner(address _newOwner)
        public
        noReentry
        onlyOwner
        returns (bool)
    {
        ChangeOwnerTo(_newOwner);
        newOwner = _newOwner;
        return true;
    }

    // To accept ownership. Required to prove new address can call the contract.
    function acceptOwnership()
        public
        noReentry
        returns (bool)
    {
        require(msg.sender == newOwner);
        ChangedOwner(owner, newOwner);
        owner = newOwner;
        return true;
    }

    // Change the address of the Veredictum contract
    function changeVeredictum(address _addr)
        public
        noReentry
        onlyOwner
        returns (bool)
    {
        veredictum = _addr;
        return true;
    }
    
    // The contract can be selfdestructed after abort and ether balance is 0.
    function destroy()
        public
        noReentry
        onlyOwner
    {
        require(!__abortFuse);
        require(this.balance == 0);
        selfdestruct(owner);
    }
    
    // Owner can salvage ERC20 tokens that may have been sent to the account
    function transferAnyERC20Token(address tokenAddress, uint amount)
        onlyOwner
        noReentry
        returns (bool) 
    {
        return ERC20Token(tokenAddress).transfer(owner, amount);
    }
}


interface Notify
{
    event Notified(address indexed _from, uint indexed _amount);
    
    function notify(address _from, uint _amount) public returns (bool);
}


contract VeredictumTest is Notify
{
    address public vnt;
    
    function setVnt(address _addr) { vnt = _addr; }
    
    function notify(address _from, uint _amount) public returns (bool)
    {
        require(msg.sender == vnt);
        Notified(_from, _amount);
        return true;
    }
}
