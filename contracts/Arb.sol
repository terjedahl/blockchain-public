// SPDX-License-Identifier: UNLICENSED

pragma solidity >=0.8.20;
pragma abicoder v2;

import { IFlashLoanRecipient } from "@balancer-labs/v2-interfaces/contracts/vault/IFlashLoanRecipient.sol";
import { IVault, IERC20 } from "@balancer-labs/v2-interfaces/contracts/vault/IVault.sol";
import { Ownable } from '@openzeppelin/contracts/access/Ownable.sol';
import { ReentrancyGuard } from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import { Strings } from "@openzeppelin/contracts/utils/Strings.sol";
//import { BytesLib } from "@uniswap/v3-periphery/contracts/libraries/BytesLib.sol";
import { BytesLib } from "./BytesLib.sol";

//import { SafeERC20, IERC20 as zIERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
//import { IERC20 as zIERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IUniV2 } from "./IUniV2.sol";
import { IBLR21 } from "./IBLR21.sol";
import { IUniV3 } from "./IUniV3.sol";
import { INA51 } from "./INA51.sol";
import { ISwapR02 } from "./ISwapR02.sol";



contract Arb is IFlashLoanRecipient, Ownable, ReentrancyGuard  {

    using Strings for uint256;
    using Strings for address;
    using BytesLib for bytes;


    event Swapped(string prot, address router, address tokenIn, uint256 amountIn, address tokenOut, uint256 amountOut);
    event LoanReceived(address sender, IERC20 token, uint256 amount, uint256 feeAmount);
    event PreArbContractSenderBalance(IERC20 token, uint256 amountContract, uint256 amountSender);
    event PostArbContractSenderBalance(IERC20 token, uint256 amountContract, uint256 amountSender);
    event ProfitMade(IERC20 token, uint256 amount);

    IVault public balancerVault;


    constructor(address _balancer) Ownable(msg.sender) {
        balancerVault = IVault(_balancer);
    }


    function setBalancer(address _balancer) external onlyOwner {
        balancerVault = IVault(_balancer);
    }


    function _UniV2(uint256 amountIn, bytes memory val) internal returns (uint256 amountOut) {
        // parse values
        (string memory prot, address router, address[] memory path)
            = abi.decode(val, (string, address, address[]));
        address tokenIn = path[0];
        address tokenOut = path[path.length - 1];

        // assert we have enough tokens and approve transfer
        require(IERC20(tokenIn).balanceOf(address(this)) >= amountIn, "_UniV2: Not enough tokens in contract");
        _safeApprove(tokenIn, router, amountIn);

        // do the swap
        uint256[] memory amountsOut = IUniV2(router).swapExactTokensForTokens(
            amountIn, 1,
            path,
            address(this),
            block.timestamp + 15  // TODO: what is a good deadline?
        );

        // process the result. amountOut is returned implicitly
        amountOut = amountsOut[amountsOut.length - 1];
        emit Swapped(prot, router, tokenIn, amountIn, tokenOut, amountOut);
    }


    // https://docs.traderjoexyz.com/guides/swap-tokens
    function _BLR21(uint256 amountIn, bytes memory val) internal returns (uint256 amountOut) {
        // parse values
        (string memory prot, address router, uint256[] memory pairBinSteps, uint8[] memory versions, address[] memory tokenPath)
            = abi.decode(val, (string, address, uint256[], uint8[], address[]));
        address tokenIn = tokenPath[0];
        address tokenOut = tokenPath[tokenPath.length - 1];

        // assert we have enough tokens and approve transfer
        require(IERC20(tokenIn).balanceOf(address(this)) >= amountIn, "_BLR21: Not enough tokens in contract");
        _safeApprove(tokenIn, router, amountIn);

        // prepare args
        IBLR21.Version[] memory versions2 = new IBLR21.Version[](versions.length);
        for(uint i = 0; i < versions.length; i++) {
            versions2[i] = IBLR21.Version(versions[i]);
        }
        IERC20[] memory tokenPath2 = new IERC20[](tokenPath.length);
        for(uint i = 0; i < tokenPath.length; i++) {
            tokenPath2[i] = IERC20(tokenPath[i]);
        }
        // do the swap
        amountOut = IBLR21(router).swapExactTokensForTokens(
            amountIn, 1,
            IBLR21.Path({
                pairBinSteps: pairBinSteps,
                versions: versions2,
                tokenPath: tokenPath2
            }),
            address(this),
            block.timestamp + 15
        );

        // process the result.  amountOut is returned implicitly
        emit Swapped(prot, router, tokenIn, amountIn, tokenOut, amountOut);
    }


    function _UniV3(uint256 amountIn, bytes memory val) internal returns (uint256 amountOut) {
        // parse values
        (string memory prot, address router, address tokenIn, uint24 feeTier, address tokenOut)
        = abi.decode(val, (string, address, address, uint24, address));

        // assert we have enough tokens and approve transfer
        require(IERC20(tokenIn).balanceOf(address(this)) >= amountIn, "_UniV3: Not enough tokens in contract");
        _safeApprove(tokenIn, router, amountIn);

        // do the swap
        amountOut = IUniV3(router).exactInputSingle(
            IUniV3.ExactInputSingleParams({
                tokenIn: tokenIn,
                tokenOut: tokenOut,
                fee: feeTier,
                recipient: address(this),
                deadline: block.timestamp + 15,  // TODO: what is a good deadline?
                amountIn: amountIn,
                amountOutMinimum: 1,
                sqrtPriceLimitX96: 0  // TODO: maybe calculate?
            })
        );

        // process the result.  amountOut is returned implicitly
        emit Swapped(prot, router, tokenIn, amountIn, tokenOut, amountOut);
    }


    function _NA51(uint256 amountIn, bytes memory val) internal returns (uint256 amountOut) {
        // parse values
        (string memory prot, address router,  bytes memory pathBytes)
          = abi.decode(val, (string, address, bytes));

        address tokenIn = pathBytes.toAddress(0); //  _getFirstAddress(pathBytes);// pathBytes.toAddress(0);
        address tokenOut = pathBytes.toAddress(pathBytes.length - 20);

        // assert we have enough tokens and approve transfer
        require(IERC20(tokenIn).balanceOf(address(this)) >= amountIn, "_NA51: Not enough tokens in contract");
        _safeApprove(tokenIn, router, amountIn);

        // do the swap
        amountOut = INA51(router).exactInput(
            INA51.ExactInputParams({
                path: pathBytes,
                recipient: address(this),
                deadline: block.timestamp + 15,  // TODO: what is a good deadline?
                amountIn: amountIn,
                amountOutMinimum: 1
            })
        );

        // process the result.  amountOut is returned implicitly
        emit Swapped(prot, router, tokenIn, amountIn, tokenOut, amountOut);
    }


    function _SwapR02(uint256 amountIn, bytes memory val) internal returns (uint256 amountOut) {
        // parse values
        (string memory prot, address router, address tokenIn, uint24 feeTier, address tokenOut)
        = abi.decode(val, (string, address, address, uint24, address));

        // assert we have enough tokens and approve transfer
        require(IERC20(tokenIn).balanceOf(address(this)) >= amountIn, "_SwapR02: Not enough tokens in contract");
        _safeApprove(tokenIn, router, amountIn);

        // do the swap
        amountOut = ISwapR02(router).exactInputSingle(
            ISwapR02.ExactInputSingleParams({
                tokenIn: tokenIn,
                tokenOut: tokenOut,
                fee: feeTier,
                recipient: address(this),
                amountIn: amountIn,
                amountOutMinimum: 1,
                sqrtPriceLimitX96: 0  // TODO: maybe calculate?
            })
        );

        // process the result.  amountOut is returned implicitly
        emit Swapped(prot, router, tokenIn, amountIn, tokenOut, amountOut);
    }


    function _swap(uint256 amountIn, string memory prot, bytes memory val) internal returns (uint256) {
        // select the correct swap function by "prot"
        if (Strings.equal(prot, "UniV2")) {
            return _UniV2(amountIn, val);
        }
        if (Strings.equal(prot, "BLR21")) {
            return _BLR21(amountIn, val);
        }
        if (Strings.equal(prot, "UniV3")) {
            return _UniV3(amountIn, val);
        }
        if (Strings.equal(prot, "NA51")) {
            return _NA51(amountIn, val);
        }
        if (Strings.equal(prot, "SwapR02")) {
            return _SwapR02(amountIn, val);
        }
        revert(string(abi.encodePacked("unknown prot: ", prot)));
    }


    function swap(uint256 amountIn, string calldata prot, bytes calldata val) external returns (uint256) {
        return _swap(amountIn, prot, val);
    }


    function _swaps(uint256 amountIn, string[] memory prots, bytes[] memory vals) internal returns (uint256 amountOut) {
        require(prots.length == vals.length, "prots and vals length mismatch");
        amountOut = amountIn;  // start with the input amount and is returned implicitly
        for (uint256 i = 0; i < prots.length; i++) {
            // pass inn previous amountOut, get new amountOut
            amountOut = _swap(amountOut, prots[i], vals[i]);
        }
    }


    function swaps(uint256 amountIn, string[] calldata prots, bytes[] calldata vals) external returns (uint256) {
        return _swaps(amountIn, prots, vals);
    }


    function arbBalancer(uint256 amount1, address token1, string[] calldata prots, bytes[] calldata vals) external nonReentrant {
        require(prots.length == vals.length, "prots and vals length mismatch");

        // the token  and amount to borrow
        IERC20[] memory tokens = new IERC20[](1);
        tokens[0] = IERC20(token1);
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = amount1;

        // encode what is needed for the swaps and trigger the flashloan
        bytes memory userData = abi.encode(amount1, token1, prots, vals);
        balancerVault.flashLoan(this, tokens, amounts, userData);
    }


    // IFlashLoanRecipient - Balancer callback
    function receiveFlashLoan(
        IERC20[] calldata tokens,
        uint256[] calldata amounts,
        uint256[] calldata feeAmounts,
        bytes calldata userData
    ) external override {
        _handleLoan(address(tokens[0]), amounts[0], feeAmounts[0], userData, address(balancerVault));
    }


    function _handleLoan(address loanToken, uint256 loanAmount, uint256 loanFee, bytes calldata userData, address loanIssuer) internal {
        emit LoanReceived(msg.sender, IERC20(loanToken), loanAmount, loanFee);
        require(msg.sender == loanIssuer, "_handleLoan: callback must be called by loaner");

        (uint256 amountIn, address tokenIn, string[] memory prots, bytes[] memory vals)
            = abi.decode(userData, (uint256, address, string[], bytes[]));

        require(loanAmount == amountIn,
            string(abi.encodePacked("_handleLoan: amount mismatch: ", loanAmount.toString(), " not = ", amountIn.toString())));
        require(loanToken == tokenIn,
            string(abi.encodePacked("_handleLoan: token mismatch: ", loanToken.toHexString(), " not == ", tokenIn.toHexString())));

        IERC20 iercIn = IERC20(tokenIn);
        uint256 balanceOfThisBefore = iercIn.balanceOf(address(this));
        emit PreArbContractSenderBalance(iercIn, balanceOfThisBefore, iercIn.balanceOf(msg.sender));
        require(balanceOfThisBefore == amountIn,
            string(abi.encodePacked("initial balance mismatch: ", balanceOfThisBefore.toString(), " not == ", amountIn.toString())));

        // do the swaps
        uint256 amountRes = _swaps(amountIn, prots, vals);

        uint256 balanceOfThisAfter = iercIn.balanceOf(address(this));
        emit PostArbContractSenderBalance(iercIn, balanceOfThisAfter, iercIn.balanceOf(msg.sender));

        // assert success
        uint256 amountOwing = loanAmount + loanFee;
        require(amountOwing < amountRes,
            string(abi.encodePacked("No profit made: ", amountOwing.toString(), " not < ", amountRes.toString())));
        require(balanceOfThisAfter == amountRes,
            string(abi.encodePacked("post balance mismatch: ", balanceOfThisAfter.toString(), " not == ", amountRes.toString())));

        // return loan
        _safeTransfer(loanToken, loanIssuer, amountOwing);

        uint256 profit = amountRes - amountOwing;
        require(iercIn.balanceOf(address(this)) == profit, "loan payback failed");

        // extract profit
        _safeTransfer(address(tokenIn), owner(), profit);
        require(iercIn.balanceOf(address(this)) == 0, "profit extraction failed");

        emit ProfitMade(iercIn, profit);
    }


    function ethBalance() external view  returns (uint256) {
        return address(this).balance;
    }

    function withdrawEthBalance() external onlyOwner {
        payable(msg.sender).transfer(address(this).balance);
    }

    function tokenBalance(address tokenAddress) external view  returns (uint256) {
        IERC20 token = IERC20(tokenAddress);
        return token.balanceOf(address(this));
    }

    function withdrawTokenBalance(address tokenAddress) external onlyOwner {
        IERC20 token = IERC20(tokenAddress);
        token.transfer(msg.sender, token.balanceOf(address(this)));
    }

    receive() external payable {}


    // copied from TransferHelper.sol
    function _safeApprove(address token, address to, uint256 value) internal {
        (bool success, bytes memory data) = token.call(abi.encodeWithSelector(IERC20.approve.selector, to, value));
        require(success && (data.length == 0 || abi.decode(data, (bool))), '_safeApprove');
    }
    function _safeTransfer(address token, address to, uint256 value) internal {
        (bool success, bytes memory data) = token.call(abi.encodeWithSelector(IERC20.transfer.selector, to, value));
        require(success && (data.length == 0 || abi.decode(data, (bool))), '_safeTransfer');
    }


    function _getFirstAddress(bytes memory data) internal pure returns (address addressOut) {
        (addressOut) = abi.decode(data, (address));
    }


//    function _startsWith(string calldata _base, string calldata _value) internal pure returns (bool) {
//        return _startsWith(bytes(_base), bytes(_value));
//    }
//
//    function _startsWith(bytes calldata _baseBytes, bytes calldata _valueBytes) internal pure returns (bool) {
//        if(_valueBytes.length > _baseBytes.length) {
//            return false;
//        }
//        for(uint i = 0; i < _valueBytes.length; i++) {
//            if(_baseBytes[i] != _valueBytes[i]) {
//                return false;
//            }
//        }
//        return true;
//    }

}
