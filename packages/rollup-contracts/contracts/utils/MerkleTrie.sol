// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.5.0;

import './BytesLib.sol';
import './RLPReader.sol';
import './RLPWriter.sol';

contract MerkleTrie {
    // TREE_RADIX determines the number of elements per branch node.
    uint256 constant TREE_RADIX = 16;
    // Branch nodes have TREE_RADIX elements plus an additional `value` slot.
    uint256 constant BRANCH_NODE_LENGTH = TREE_RADIX + 1;
    // Leaf nodes and extension nodes always have two elements, a `path` and a `value`.
    uint256 constant LEAF_OR_EXTENSION_NODE_LENGTH = 2;

    // Prefixes are prepended to the `path` within a leaf or extension node and
    // allow us to differentiate between the two node types. `ODD` or `EVEN` is
    // determined by the number of nibbles within the unprefixed `path`. If the
    // number of nibbles if even, we need to insert an extra padding nibble so
    // the resulting prefixed `path` has an even number of nibbles.
    uint8 constant PREFIX_EXTENSION_EVEN = 0;
    uint8 constant PREFIX_EXTENSION_ODD = 1;
    uint8 constant PREFIX_LEAF_EVEN = 2;
    uint8 constant PREFIX_LEAF_ODD = 3;

    // Just a utility constant. RLP represents `NULL` as 0x80.
    bytes1 constant RLP_NULL = bytes1(0x80);

    enum NodeType {
        BranchNode,
        ExtensionNode,
        LeafNode
    }

    struct TrieNode {
        bytes encoded;
        RLPReader.RLPItem[] decoded;
    }


    /*
     * Public Functions
     */

    /**
     * @notice Verifies a proof that a given key/value pair is present in the
     * Merkle trie.
     * @param _key Key of the node to search for, as a hex string.
     * @param _value Value of the node to search for, as a hex string.
     * @param _proof Merkle trie inclusion proof for the desired node. Unlike
     * traditional Merkle trees, this proof is executed top-down and consists
     * of a list of RLP-encoded nodes that make a path down to the target node.
     * @param _root Known root of the Merkle trie. Used to verify that the
     * included proof is correctly constructed.
     * @return `true` if the k/v pair exists in the trie, `false` otherwise.
     */
    function verifyInclusionProof(
        bytes memory _key,
        bytes memory _value,
        bytes memory _proof,
        bytes32 _root
    ) public pure returns (bool) {
        return verifyProof(_key, _value, _proof, _root, true);
    }

    /**
     * @notice Verifies a proof that a given key/value pair is *not* present in
     * the Merkle trie.
     * @param _key Key of the node to search for, as a hex string.
     * @param _value Value of the node to search for, as a hex string.
     * @param _proof Merkle trie inclusion proof for the node *nearest* the
     * target node. We effectively need to show that either the key exists and
     * its value differs, or the key does not exist at all.
     * @param _root Known root of the Merkle trie. Used to verify that the
     * included proof is correctly constructed.
     * @return `true` if the k/v pair is absent in the trie, `false` otherwise.
     */
    function verifyExclusionProof(
        bytes memory _key,
        bytes memory _value,
        bytes memory _proof,
        bytes32 _root
    ) public pure returns (bool) {
        return verifyProof(_key, _value, _proof, _root, false);
    }

    /**
     * @notice Updates a Merkle trie and returns a new root hash.
     * @param _key Key of the node to update, as a hex string.
     * @param _value Value of the node to update, as a hex string.
     * @param _proof Merkle trie inclusion proof for the node *nearest* the
     * target node. If the key exists, we can simply update the value.
     * Otherwise, we need to modify the trie to handle the new k/v pair.
     * @param _root Known root of the Merkle trie. Used to verify that the
     * included proof is correctly constructed.
     * @return Root hash of the newly constructed trie.
     */
    function update(
        bytes memory _key,
        bytes memory _value,
        bytes memory _proof,
        bytes32 _root
    ) public pure returns (bytes32) {
        TrieNode[] memory proof = parseProof(_proof);
        (uint256 pathLength, bytes memory keyRemainder, ) = walkNodePath(proof, _key, _root);

        TrieNode[] memory newPath = getNewPath(proof, pathLength, keyRemainder, _value);

        return getUpdatedTrieRoot(newPath, _key);
    }


    /*
     * Internal Functions
     */

    /**
     * @notice Utility function that handles verification of inclusion or
     * exclusion proofs. Since the verification methods are almost identical,
     * it's easier to shove this into a single function.
     * @param _key Key of the node to search for, as a hex string.
     * @param _value Value of the node to search for, as a hex string.
     * @param _proof Merkle trie inclusion proof for the node *nearest* the
     * target node. If we're proving explicit inclusion, the nearest node
     * should be the target node.
     * @param _root Known root of the Merkle trie. Used to verify that the
     * included proof is correctly constructed.
     * @param _inclusion Whether to check for inclusion or exclusion.
     * @return `true` if the k/v pair is (in/not in) the trie, `false` otherwise.
     */
    function verifyProof(
        bytes memory _key,
        bytes memory _value,
        bytes memory _proof,
        bytes32 _root,
        bool _inclusion
    ) internal pure returns (bool) {
        TrieNode[] memory proof = parseProof(_proof);
        (uint256 pathLength, bytes memory keyRemainder, bool isFinalNode) = walkNodePath(proof, _key, _root);

        if (_inclusion) {
            return (
                keyRemainder.length == 0 &&
                BytesLib.equal(getNodeValue(proof[pathLength - 1]), _value)
            );
        } else {
            return (
                (keyRemainder.length == 0 && !BytesLib.equal(getNodeValue(proof[pathLength - 1]), _value)) ||
                (keyRemainder.length != 0 && isFinalNode)
            );
        }
    }

    /**
     * @notice Walks through a proof using a provided key.
     * @param _proof Inclusion proof to walk through.
     * @param _key Key to use for the walk.
     * @param _root Known root of the trie.
     * @return (
     *     Length of the final path;
     *     Portion of the key remaining after the walk;
     *     Whether or not we've hit a dead end;
     * )
     */
    function walkNodePath(
        TrieNode[] memory _proof,
        bytes memory _key,
        bytes32 _root
    ) internal pure returns (
        uint256,
        bytes memory,
        bool
    ) {
        uint256 pathLength = 0;
        bytes memory key = BytesLib.toNibbles(_key);

        bytes32 currentNodeID = _root;
        uint256 currentKeyIndex = 0;
        uint256 currentKeyIncrement = 0;
        TrieNode memory currentNode;

        for (uint256 i = 0; i < _proof.length; i++) {
            currentNode = _proof[i];
            currentKeyIndex += currentKeyIncrement;
            pathLength += 1;

            if (currentKeyIndex == 0) {
                // First proof element is always the root node.
                require(
                    keccak256(currentNode.encoded) == currentNodeID,
                    "Invalid root hash"
                );
            } else if (currentNode.encoded.length >= 32) {
                // Nodes 32 bytes or larger are hashed inside branch nodes.
                require(
                    keccak256(currentNode.encoded) == currentNodeID,
                    "Invalid large internal hash"
                );
            } else {
                // Nodes smaller than 31 bytes aren't hashed.
                require(
                    BytesLib.toBytes32(currentNode.encoded) == currentNodeID,
                    "Invalid internal node hash"
                );
            }

            if (currentNode.decoded.length == BRANCH_NODE_LENGTH) {
                if (currentKeyIndex == key.length) {
                    break;
                } else {
                    uint8 branchKey = uint8(key[currentKeyIndex]);
                    RLPReader.RLPItem memory nextNode = currentNode.decoded[branchKey];
                    currentNodeID = getNodeID(nextNode);
                    currentKeyIncrement = 1;
                    continue;
                }
            } else if (currentNode.decoded.length == LEAF_OR_EXTENSION_NODE_LENGTH) {
                bytes memory path = getNodePath(currentNode);
                uint8 prefix = uint8(path[0]);
                uint8 offset = 2 - prefix % 2;
                bytes memory pathRemainder = BytesLib.slice(path, offset);
                bytes memory keyRemainder = BytesLib.slice(key, currentKeyIndex);
                uint256 sharedNibbleLength = getSharedNibbleLength(pathRemainder, keyRemainder);

                if (prefix == PREFIX_LEAF_EVEN || prefix == PREFIX_LEAF_ODD) {
                    if (pathRemainder.length == sharedNibbleLength && keyRemainder.length == sharedNibbleLength) {
                        currentKeyIndex += sharedNibbleLength;
                    }
                    currentNodeID = bytes32(RLP_NULL);
                    break;
                } else if (prefix == PREFIX_EXTENSION_EVEN || prefix == PREFIX_EXTENSION_ODD) {
                    if (sharedNibbleLength == 0) {
                        currentNodeID = bytes32(RLP_NULL);
                        break;
                    } else {
                        currentNodeID = getNodeID(currentNode.decoded[1]);
                        currentKeyIncrement = sharedNibbleLength;
                        continue;
                    }
                }
            }
        }

        bool isFinalNode = currentNodeID == bytes32(RLP_NULL);
        return (pathLength, BytesLib.slice(key, currentKeyIndex), isFinalNode);
    }

    /**
     * @notice Creates new nodes to support a k/v pair insertion into a given
     * Merkle trie path.
     * @param _path Path to the node nearest the k/v pair.
     * @param _pathLength Length of the path. Necessary because the provided
     * path may include additional nodes (e.g., it comes directly from a proof)
     * and we can't resize in-memory arrays without costly duplication.
     * @param _keyRemainder Portion of the initial key that must be inserted
     * into the trie.
     * @param _value Value to insert at the given key.
     * @return A new path with the inserted k/v pair and extra supporting nodes.
     */
    function getNewPath(
        TrieNode[] memory _path,
        uint256 _pathLength,
        bytes memory _keyRemainder,
        bytes memory _value
    ) internal pure returns (TrieNode[] memory) {
        bytes memory keyRemainder = _keyRemainder;

        TrieNode memory lastNode = _path[_pathLength - 1];
        NodeType lastNodeType = getNodeType(lastNode);

        TrieNode[] memory newNodes = new TrieNode[](3);
        uint256 totalNewNodes = 0;

        if (keyRemainder.length == 0 && lastNodeType == NodeType.LeafNode) {
            newNodes[totalNewNodes] = makeLeafNode(getNodeKey(lastNode), _value);
            totalNewNodes += 1;
        } else if (lastNodeType == NodeType.BranchNode) {
            if (keyRemainder.length == 0) {
                newNodes[totalNewNodes] = editBranchValue(lastNode, _value);
                totalNewNodes += 1;
            } else {
                newNodes[totalNewNodes] = lastNode;
                totalNewNodes += 1;
                newNodes[totalNewNodes] = makeLeafNode(BytesLib.slice(keyRemainder, 1), _value);
                totalNewNodes += 1;
            }
        } else {
            bytes memory lastNodeKey = getNodeKey(lastNode);
            uint256 sharedNibbleLength = getSharedNibbleLength(lastNodeKey, keyRemainder);

            if (sharedNibbleLength != 0) {
                bytes memory nextNodeKey = BytesLib.slice(lastNodeKey, 0, sharedNibbleLength);
                newNodes[totalNewNodes] = makeExtensionNode(nextNodeKey, getNodeHash(_value));
                totalNewNodes += 1;
                lastNodeKey = BytesLib.slice(lastNodeKey, sharedNibbleLength);
                keyRemainder = BytesLib.slice(keyRemainder, sharedNibbleLength);
            }

            TrieNode memory newBranch = makeEmptyBranchNode();

            if (lastNodeKey.length == 0) {
                newBranch = editBranchValue(newBranch, getNodeValue(lastNode));
            } else {
                uint8 branchKey = uint8(lastNodeKey[0]);
                lastNodeKey = BytesLib.slice(lastNodeKey, 1);

                if (lastNodeKey.length != 0 || lastNodeType == NodeType.LeafNode) {
                    TrieNode memory modifiedLastNode = makeLeafNode(lastNodeKey, getNodeValue(lastNode));
                    newBranch = editBranchIndex(newBranch, branchKey, getNodeHash(modifiedLastNode.encoded));
                } else {
                    newBranch = editBranchIndex(newBranch, branchKey, getNodeValue(lastNode));
                }
            }

            if (keyRemainder.length == 0) {
                newBranch = editBranchValue(newBranch, _value);
                newNodes[totalNewNodes] = newBranch;
                totalNewNodes += 1;
            } else {
                keyRemainder = BytesLib.slice(keyRemainder, 1);
                newNodes[totalNewNodes] = newBranch;
                totalNewNodes += 1;
                newNodes[totalNewNodes] = makeLeafNode(keyRemainder, _value);
                totalNewNodes += 1;
            }
        }

        return joinNodeArrays(_path, _pathLength - 1, newNodes, totalNewNodes);
    }

    /**
     * @notice Computes the trie root from a given path.
     * @param _nodes Path to some k/v pair.
     * @param _key Key for the k/v pair.
     * @return Root hash for the updated trie.
     */
    function getUpdatedTrieRoot(
        TrieNode[] memory _nodes,
        bytes memory _key
    ) internal pure returns (bytes32) {
        bytes memory key = BytesLib.toNibbles(_key);

        TrieNode memory currentNode;
        NodeType currentNodeType;
        bytes memory previousNodeHash;

        for (uint256 i = _nodes.length; i > 0; i--) {
            currentNode = _nodes[i - 1];
            currentNodeType = getNodeType(currentNode);

            if (currentNodeType == NodeType.LeafNode) {
                bytes memory nodeKey = getNodeKey(currentNode);
                key = BytesLib.slice(key, 0, key.length - nodeKey.length);
            } else if (currentNodeType == NodeType.ExtensionNode) {
                bytes memory nodeKey = getNodeKey(currentNode);
                key = BytesLib.slice(key, 0, key.length - nodeKey.length);

                if (previousNodeHash.length > 0) {
                    currentNode = makeExtensionNode(nodeKey, previousNodeHash);
                }
            } else if (currentNodeType == NodeType.BranchNode) {
                if (previousNodeHash.length > 0) {
                    uint8 branchKey = uint8(key[key.length - 1]);
                    key = BytesLib.slice(key, 0, key.length - 1);
                    currentNode = editBranchIndex(currentNode, branchKey, previousNodeHash);
                }
            }

            previousNodeHash = getNodeHash(currentNode.encoded);
        }

        return keccak256(currentNode.encoded);
    }

    /**
     * @notice Parses an RLP-encoded proof into something more useful.
     * @param _proof RLP-encoded proof to parse.
     * @return Proof parsed into easily accessible structs.
     */
    function parseProof(
        bytes memory _proof
    ) internal pure returns (TrieNode[] memory) {
        RLPReader.RLPItem[] memory nodes = RLPReader.toList(RLPReader.toRlpItem(_proof));
        TrieNode[] memory proof = new TrieNode[](nodes.length);

        for (uint256 i = 0; i < nodes.length; i++) {
            bytes memory encoded = RLPReader.toBytes(nodes[i]);
            proof[i] = TrieNode({
                encoded: encoded,
                decoded: RLPReader.toList(RLPReader.toRlpItem(encoded))
            });
        }

        return proof;
    }

    /**
     * @notice Picks out the ID for a node. Node ID is referred to as the
     * "hash" within the specification, but nodes < 32 bytes are not actually
     * hashed.
     * @param _node Node to pull an ID for.
     * @return ID for the node, depending on the size of its contents.
     */
    function getNodeID(
        RLPReader.RLPItem memory _node
    ) internal pure returns (bytes32) {
        bytes memory nodeID;

        if (_node.len < 32) {
            // Nodes smaller than 32 bytes are RLP encoded.
            nodeID = RLPReader.toRlpBytes(_node);
        } else {
            // Nodes 32 bytes or larger are hashed.
            nodeID = RLPReader.toBytes(_node);
        }

        return BytesLib.toBytes32(nodeID);
    }

    /**
     * @notice Gets the path for a leaf or extension node.
     * @param _node Node to get a path for.
     * @return Node path, converted to an array of nibbles.
     */
    function getNodePath(
        TrieNode memory _node
    ) internal pure returns (bytes memory) {
        return BytesLib.toNibbles(RLPReader.toBytes(_node.decoded[0]));
    }

    /**
     * @notice Gets the key for a leaf or extension node. Keys are essentially
     * just paths without any prefix.
     * @param _node Node to get a key for.
     * @return Node key, converted to an array of nibbles.
     */
    function getNodeKey(
        TrieNode memory _node
    ) internal pure returns (bytes memory) {
        return removeHexPrefix(getNodePath(_node));
    }

    /**
     * @notice Gets the path for a node.
     * @param _node Node to get a value for.
     * @return Node value, as hex bytes.
     */
    function getNodeValue(
        TrieNode memory _node
    ) internal pure returns (bytes memory) {
        return RLPReader.toBytes(_node.decoded[_node.decoded.length - 1]);
    }

    /**
     * @notice Computes the node hash for an encoded node. Nodes < 32 bytes
     * are not hashed, all others are keccak256 hashed.
     * @param _encoded Encoded node to hash.
     * @return Hash of the encoded node. Simply the input if < 32 bytes.
     */
    function getNodeHash(
        bytes memory _encoded
    ) internal pure returns (bytes memory) {
        if (_encoded.length < 32) {
            return _encoded;
        } else {
            return abi.encodePacked(keccak256(_encoded));
        }
    }

    /**
     * @notice Determines the type for a given node.
     * @param _node Node to determine a type for.
     * @return Type of the node; BranchNode/ExtensionNode/LeafNode.
     */
    function getNodeType(
        TrieNode memory _node
    ) internal pure returns (NodeType) {
        if (_node.decoded.length == BRANCH_NODE_LENGTH) {
            return NodeType.BranchNode;
        } else if (_node.decoded.length == LEAF_OR_EXTENSION_NODE_LENGTH) {
            bytes memory path = getNodePath(_node);
            uint8 prefix = uint8(path[0]);
            if (prefix == PREFIX_LEAF_EVEN || prefix == PREFIX_LEAF_ODD) {
                return NodeType.LeafNode;
            } else if (prefix == PREFIX_EXTENSION_EVEN || prefix == PREFIX_EXTENSION_ODD) {
                return NodeType.ExtensionNode;
            }
        }

        revert("Invalid node type");
    }

    /**
     * @notice Utility; determines the number of nibbles shared between two
     * nibble arrays.
     * @param _a First nibble array.
     * @param _b Second nibble array.
     * @return Number of shared nibbles.
     */
    function getSharedNibbleLength(bytes memory _a, bytes memory _b) internal pure returns (uint256) {
        uint256 i = 0;
        while (_a.length > i && _b.length > i && _a[i] == _b[i]) {
            i++;
        }
        return i;
    }

    /**
     * @notice Utility; converts an RLP-encoded node into our nice struct.
     * @param _raw RLP-encoded node to convert.
     * @return Node as a TrieNode struct.
     */
    function makeNode(
        bytes[] memory _raw
    ) internal pure returns (TrieNode memory) {
        bytes memory encoded = RLPWriter.encodeList(_raw);

        return TrieNode({
            encoded: encoded,
            decoded: RLPReader.toList(RLPReader.toRlpItem(encoded))
        });
    }

    /**
     * @notice Utility; converts an RLP-decoded node into our nice struct.
     * @param _items RLP-decoded node to convert.
     * @return Node as a TrieNode struct.
     */
    function makeNode(
        RLPReader.RLPItem[] memory _items
    ) internal pure returns (TrieNode memory) {
        bytes[] memory raw = new bytes[](_items.length);
        for (uint256 i = 0; i < _items.length; i++) {
            raw[i] = RLPReader.toRlpBytes(_items[i]);
        }
        return makeNode(raw);
    }

    /**
     * @notice Creates a new extension node.
     * @param _key Key for the extension node, unprefixed.
     * @param _value Value for the extension node.
     * @return New extension node with the given k/v pair.
     */
    function makeExtensionNode(
        bytes memory _key,
        bytes memory _value
    ) internal pure returns (TrieNode memory) {
        bytes[] memory raw = new bytes[](2);
        bytes memory key = addHexPrefix(_key, false);
        raw[0] = RLPWriter.encodeBytes(BytesLib.fromNibbles(key));
        raw[1] = RLPWriter.encodeBytes(_value);
        return makeNode(raw);
    }

    /**
     * @notice Creates a new leaf node.
     * @param _key Key for the leaf node, unprefixed.
     * @param _value Value for the leaf node.
     * @return New leaf node with the given k/v pair.
     */
    function makeLeafNode(
        bytes memory _key,
        bytes memory _value
    ) internal pure returns (TrieNode memory) {
        bytes[] memory raw = new bytes[](2);
        bytes memory key = addHexPrefix(_key, true);
        raw[0] = RLPWriter.encodeBytes(BytesLib.fromNibbles(key));
        raw[1] = RLPWriter.encodeBytes(_value);
        return makeNode(raw);
    }

    /**
     * @notice Creates an empty branch node.
     * @return Empty branch node as a TrieNode stuct.
     */
    function makeEmptyBranchNode() internal pure returns (TrieNode memory) {
        bytes[] memory raw = new bytes[](BRANCH_NODE_LENGTH);
        for (uint256 i = 0; i < raw.length; i++) {
            raw[i] = hex'80';
        }
        return makeNode(raw);
    }

    /**
     * @notice Modifies the value slot for a given branch.
     * @param _branch Branch node to modify.
     * @param _value Value to insert into the branch.
     * @return Modified branch node.
     */
    function editBranchValue(
        TrieNode memory _branch,
        bytes memory _value
    ) internal pure returns (TrieNode memory) {
        bytes memory encoded = RLPWriter.encodeBytes(_value);
        _branch.decoded[_branch.decoded.length - 1] = RLPReader.toRlpItem(encoded);
        return makeNode(_branch.decoded);
    }

    /**
     * @notice Modifies a slot at an index for a given branch.
     * @param _branch Branch node to modify.
     * @param _index Slot index to modify.
     * @param _value Value to insert into the slot.
     * @return Modified branch node.
     */
    function editBranchIndex(
        TrieNode memory _branch,
        uint8 _index,
        bytes memory _value
    ) internal pure returns (TrieNode memory) {
        bytes memory encoded = _value.length < 32 ? _value : RLPWriter.encodeBytes(_value);
        _branch.decoded[_index] = RLPReader.toRlpItem(encoded);
        return makeNode(_branch.decoded);
    }

    /**
     * @notice Utility; adds a prefix to a key.
     * @param _key Key to prefix.
     * @param _isLeaf Whether or not the key belongs to a leaf.
     * @return Prefixed key.
     */
    function addHexPrefix(
        bytes memory _key,
        bool _isLeaf
    ) internal pure returns (bytes memory) {
        uint8 prefix = _isLeaf ? uint8(0x02) : uint8(0x00);
        uint8 offset = uint8(_key.length % 2);
        bytes memory prefixed = new bytes(2 - offset);
        prefixed[0] = bytes1(prefix + offset);
        return BytesLib.concat(prefixed, _key);
    }

    /**
     * @notice Utility; removes a prefix from a path.
     * @param _path Path to remove the prefix from.
     * @return Unprefixed key.
     */
    function removeHexPrefix(
        bytes memory _path
    ) internal pure returns (bytes memory) {
        if (uint8(_path[0]) % 2 == 0) {
            return BytesLib.slice(_path, 2);
        } else {
            return BytesLib.slice(_path, 1);
        }
    }

    /**
     * @notice Utility; combines two node arrays. Array lengths are required
     * because the actual lengths may be longer than the filled lengths.
     * Array resizing is extremely costly and should be avoided.
     * @param _a First array to join.
     * @param _aLength Length of the first array.
     * @param _b Second array to join.
     * @param _bLength Length of the second array.
     * @return Combined node array.
     */
    function joinNodeArrays(
        TrieNode[] memory _a,
        uint256 _aLength,
        TrieNode[] memory _b,
        uint256 _bLength
    ) internal pure returns (TrieNode[] memory) {
        TrieNode[] memory ret = new TrieNode[](_aLength + _bLength);

        for (uint256 i = 0; i < _aLength; i++) {
            ret[i] = _a[i];
        }

        for (uint256 i = 0; i < _bLength; i++) {
            ret[i + _aLength] = _b[i];
        }

        return ret;
    }
}