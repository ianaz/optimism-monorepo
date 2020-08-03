pragma solidity ^0.5.0;
pragma experimental ABIEncoderV2;
import { ERC20 } from "./ERC20.sol";
import { DataTypes } from "../utils/DataTypes.sol";
import { L2ToL1MessagePasser } from "../ovm/precompiles/L2ToL1MessagePasser.sol";
import { DepositedERC20 } from "./DepositedERC20.sol";


contract L2ERC20Bridge {

    address l1ERC20Bridge;
    uint public withdrawalNonce = 0;
    mapping (address => address) public correspondingL1ERC20;
    mapping (address => address) public correspondingDepositedERC20;

    constructor (address _l1ERC20Bridge) public {
        l1ERC20Bridge = _l1ERC20Bridge;
    }

    /*
    * Public functions
    */

    /*
    * Creates a new L2 ERC20 deposit contract if one does not already
    * exist for the corresponding L1 ERC20 contract address, then updates
    * the mappings of respective L1 and L2 ERC20 contracts for the same asset
    */
    function deployNewDepositedERC20(
        address l1ERC20Address
    ) public {
        require(correspondingDepositedERC20[l1ERC20Address] == address(0),"L2 ERC20 Contract for this asset already exists.");
        address newDepositedERC20 = address(new DepositedERC20());
        // Set the mappings
        correspondingDepositedERC20[l1ERC20Address] = newDepositedERC20;
        correspondingL1ERC20[newDepositedERC20] = l1ERC20Address;
    }

    function forwardDeposit(
        address _depositer,
        uint _amount,
        address _l1ERC20Address
    ) public {
        DepositedERC20 l2ERC20Contract = DepositedERC20(correspondingDepositedERC20[_l1ERC20Address]);
        l2ERC20Contract.processDeposit(_depositer, _amount);
    }

    function forwardWithdrawal(
        address _withdrawTo,
        uint _amount
    ) public {
        address _l1ERC20Address = correspondingL1ERC20[msg.sender];
        DataTypes.Withdrawal memory withdrawal = DataTypes.Withdrawal ({
            withdrawTo: _withdrawTo,
            amount: _amount,
            l1ERC20Address: _l1ERC20Address,
            nonce: withdrawalNonce
        });
        L2ToL1MessagePasser l2ToL1MessagePasser = new L2ToL1MessagePasser(address(this));
        l2ToL1MessagePasser.passMessageToL1(
            abi.encode(withdrawal)
        );
    }
}