// SPDX-License-Identifier: MIT
pragma solidity 0.8.15;

import {
    OwnableUpgradeable
} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import { Semver } from "../universal/Semver.sol";

/**
 * @title SystemConfig
 * @notice The SystemConfig contract is used to manage configuration of an Optimism network. All
 *         configuration is stored on L1 and picked up by L2 as part of the derviation of the L2
 *         chain.
 */
contract SystemConfig is OwnableUpgradeable, Semver {
    /**
     * @notice Enum representing different types of updates.
     *
     * @custom:value BATCHER              Represents an update to the batcher hash.
     * @custom:value GAS_CONFIG           Represents an update to txn fee config on L2.
     * @custom:value GAS_LIMIT            Represents an update to gas limit on L2.
     * @custom:value UNSAFE_BLOCK_SIGNER  Represents an update to the signer key for unsafe
     *                                    block distrubution.
     */
    enum UpdateType {
        BATCHER,
        GAS_CONFIG,
        GAS_LIMIT,
        UNSAFE_BLOCK_SIGNER
    }

    /**
     * @notice Represents the configuration for the EIP-1559 based curve for
     *         the deposit gas market. These values should be set with care
     *         as it is possible to set them in a way that breaks the deposit
     *         gas market. The target resource limit is defined as
     *         maxResourceLimit / elasticityMultiplier.
     *         This struct was designed to fit within a single word. There is
     *         additional space for additions in the future.
     *
     * @custom:field maxResourceLimit             Represents the maximum amount of deposit
     *                                            gas that can be purchased per block.
     * @custom:field elasticityMultiplier         Determines the target resource limit
     *                                            along with the resource limit.
     * @custom:field baseFeeMaxChangeDenominator  Determines max change on fee per block.
     * @custom:field minimumBaseFee               The min deposit base fee, it is clamped to this
     *                                            value.
     * @custom:field systemTxMaxGas               The amount of gas supplied to the system
     *                                            transaction.
     * @custom:field maximumBaseFee               The max deposit base fee, it is clamped to this
     *                                            value.
     */
    struct ResourceConfig {
        uint32 maxResourceLimit;
        uint8 elasticityMultiplier;
        uint8 baseFeeMaxChangeDenominator;
        uint32 minimumBaseFee;
        uint32 systemTxMaxGas;
        uint128 maximumBaseFee;
    }

    /**
     * @notice Version identifier, used for upgrades.
     */
    uint256 public constant VERSION = 0;

    /**
     * @notice Storage slot that the unsafe block signer is stored at. Storing it at this
     *         deterministic storage slot allows for decoupling the storage layout from the way
     *         that `solc` lays out storage. The `op-node` uses a storage proof to fetch this value.
     */
    bytes32 public constant UNSAFE_BLOCK_SIGNER_SLOT = keccak256("systemconfig.unsafeblocksigner");

    /**
     * @notice Minimum gas limit. This should not be lower than the maximum deposit gas resource
     *         limit in the ResourceMetering contract used by OptimismPortal, to ensure the L2
     *         block always has sufficient gas to process deposits.
     */
    uint64 public constant MINIMUM_GAS_LIMIT = 8_000_000;

    /**
     * @notice Fixed L2 gas overhead. Used as part of the L2 fee calculation.
     */
    uint256 public overhead;

    /**
     * @notice Dynamic L2 gas overhead. Used as part of the L2 fee calculation.
     */
    uint256 public scalar;

    /**
     * @notice Identifier for the batcher. For version 1 of this configuration, this is represented
     *         as an address left-padded with zeros to 32 bytes.
     */
    bytes32 public batcherHash;

    /**
     * @notice L2 block gas limit.
     */
    uint64 public gasLimit;

    /**
     * @notice The configuration for the deposit fee market. Used by the OptimismPortal
     *         to meter the cost of buying L2 gas on L1.
     */
    ResourceConfig internal _resourceConfig;

    /**
     * @notice Emitted when configuration is updated
     *
     * @param version    SystemConfig version.
     * @param updateType Type of update.
     * @param data       Encoded update data.
     */
    event ConfigUpdate(uint256 indexed version, UpdateType indexed updateType, bytes data);

    /**
     * @custom:semver 1.1.0
     *
     * @param _owner             Initial owner of the contract.
     * @param _overhead          Initial overhead value.
     * @param _scalar            Initial scalar value.
     * @param _batcherHash       Initial batcher hash.
     * @param _gasLimit          Initial gas limit.
     * @param _unsafeBlockSigner Initial unsafe block signer address.
     * @param _config            Initial resource config.
     */
    constructor(
        address _owner,
        uint256 _overhead,
        uint256 _scalar,
        bytes32 _batcherHash,
        uint64 _gasLimit,
        address _unsafeBlockSigner,
        ResourceConfig memory _config
    ) Semver(1, 1, 0) {
        initialize({
            _owner: _owner,
            _overhead: _overhead,
            _scalar: _scalar,
            _batcherHash: _batcherHash,
            _gasLimit: _gasLimit,
            _unsafeBlockSigner: _unsafeBlockSigner,
            _config: _config
        });
    }

    /**
     * @notice Initializer. The resource config must be set before the
     *         require check.
     *
     * @param _owner             Initial owner of the contract.
     * @param _overhead          Initial overhead value.
     * @param _scalar            Initial scalar value.
     * @param _batcherHash       Initial batcher hash.
     * @param _gasLimit          Initial gas limit.
     * @param _unsafeBlockSigner Initial unsafe block signer address.
     * @param _config            Initial ResourceConfig.
     */
    function initialize(
        address _owner,
        uint256 _overhead,
        uint256 _scalar,
        bytes32 _batcherHash,
        uint64 _gasLimit,
        address _unsafeBlockSigner,
        ResourceConfig memory _config
    ) public initializer {
        __Ownable_init();
        transferOwnership(_owner);
        overhead = _overhead;
        scalar = _scalar;
        batcherHash = _batcherHash;
        gasLimit = _gasLimit;
        _setUnsafeBlockSigner(_unsafeBlockSigner);
        _setResourceConfig(_config);
        require(_gasLimit >= minimumGasLimit(), "SystemConfig: gas limit too low");
    }

    /**
     * @notice High level getter for the unsafe block signer address. Unsafe blocks can be
     *         propagated across the p2p network if they are signed by the key corresponding to
     *         this address.
     *
     * @return Address of the unsafe block signer.
     */
    // solhint-disable-next-line ordering
    function unsafeBlockSigner() external view returns (address) {
        address addr;
        bytes32 slot = UNSAFE_BLOCK_SIGNER_SLOT;
        assembly {
            addr := sload(slot)
        }
        return addr;
    }

    /**
     * @notice Updates the unsafe block signer address.
     *
     * @param _unsafeBlockSigner New unsafe block signer address.
     */
    function setUnsafeBlockSigner(address _unsafeBlockSigner) external onlyOwner {
        _setUnsafeBlockSigner(_unsafeBlockSigner);

        bytes memory data = abi.encode(_unsafeBlockSigner);
        emit ConfigUpdate(VERSION, UpdateType.UNSAFE_BLOCK_SIGNER, data);
    }

    /**
     * @notice Updates the batcher hash.
     *
     * @param _batcherHash New batcher hash.
     */
    function setBatcherHash(bytes32 _batcherHash) external onlyOwner {
        batcherHash = _batcherHash;

        bytes memory data = abi.encode(_batcherHash);
        emit ConfigUpdate(VERSION, UpdateType.BATCHER, data);
    }

    /**
     * @notice Updates gas config.
     *
     * @param _overhead New overhead value.
     * @param _scalar   New scalar value.
     */
    function setGasConfig(uint256 _overhead, uint256 _scalar) external onlyOwner {
        overhead = _overhead;
        scalar = _scalar;

        bytes memory data = abi.encode(_overhead, _scalar);
        emit ConfigUpdate(VERSION, UpdateType.GAS_CONFIG, data);
    }

    /**
     * @notice Updates the L2 gas limit.
     *
     * @param _gasLimit New gas limit.
     */
    function setGasLimit(uint64 _gasLimit) external onlyOwner {
        require(_gasLimit >= minimumGasLimit(), "SystemConfig: gas limit too low");
        gasLimit = _gasLimit;

        bytes memory data = abi.encode(_gasLimit);
        emit ConfigUpdate(VERSION, UpdateType.GAS_LIMIT, data);
    }

    /**
     * @notice Low level setter for the unsafe block signer address. This function exists to
     *         deduplicate code around storing the unsafeBlockSigner address in storage.
     *
     * @param _unsafeBlockSigner New unsafeBlockSigner value.
     */
    function _setUnsafeBlockSigner(address _unsafeBlockSigner) internal {
        bytes32 slot = UNSAFE_BLOCK_SIGNER_SLOT;
        assembly {
            sstore(slot, _unsafeBlockSigner)
        }
    }

    /**
     * @notice A getter for the resource config. Ensures that the struct is
     *         returned instead of a tuple.
     */
    function resourceConfig() external view returns (ResourceConfig memory) {
        return _resourceConfig;
    }

    /**
     * @notice An external setter for the resource config. In the future, this
     *         method may emit an event that the `op-node` picks up for when the
     *         resource config is changed.
     *
     * @param _config The new resource config values.
     */
    function setResourceConfig(ResourceConfig memory _config) external onlyOwner {
        _setResourceConfig(_config);
    }

    /**
     * @notice An internal setter for the resource config. Ensures that the
     *         config is sane before storing it. Holds the following invariants:
     *         - min base fee must be less than or equal to max base fee
     *         - base fee change denominator must be greater than 0
     *         - max resource limit plus system tx gas must be less than or
     *           equal to the L2 gas limit
     *         - elasticity multiplier must be greater than 0
     *         - no precision loss when computing target resource limit
     *
     * @param _config The new resource config
     */
    function _setResourceConfig(ResourceConfig memory _config) internal {
        require(
            _config.minimumBaseFee <= _config.maximumBaseFee,
            "SystemConfig: min base fee must be less than max base"
        );
        require(_config.baseFeeMaxChangeDenominator > 0, "SystemConfig: denominator cannot be 0");
        require(
            _config.maxResourceLimit + _config.systemTxMaxGas <= gasLimit,
            "SystemConfig: gas limit too low"
        );
        require(
            _config.elasticityMultiplier > 0,
            "SystemConfig: elasticity multiplier cannot be 0"
        );
        require(
            ((_config.maxResourceLimit / _config.elasticityMultiplier) *
                _config.elasticityMultiplier) == _config.maxResourceLimit,
            "SystemConfig: precision loss with target resource limit"
        );

        _resourceConfig = _config;
    }

    /**
     * @notice Returns the minimum L2 gas limit that can be safely set for the system to
     *         operate. The L2 gas limit must be larger than or equal to the amount of
     *         gas that is allocated for deposits per block plus the amount of gas that
     *         is allocated for the system transaction.
     *         This function is used to determine if changes to parameters are safe.
     */
    function minimumGasLimit() public view returns (uint64) {
        return uint64(_resourceConfig.maxResourceLimit) + uint64(_resourceConfig.systemTxMaxGas);
    }
}
