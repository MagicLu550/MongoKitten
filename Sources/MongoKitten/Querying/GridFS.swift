//
// This source file is part of the MongoKitten open source project
//
// Copyright (c) 2016 - 2017 OpenKitten and the MongoKitten project authors
// Licensed under MIT
//
// See https://github.com/OpenKitten/MongoKitten/blob/mongokitten31/LICENSE.md for license information
// See https://github.com/OpenKitten/MongoKitten/blob/mongokitten31/CONTRIBUTORS.md for the list of MongoKitten project authors
//

import BSON
import Foundation
import CLibreSSL

/// A GridFS instance similar to a collection
///
/// Conforms to the GridFS standard as specified here: https://docs.mongodb.org/manual/core/gridfs/
public class GridFS {
    /// The bucket for file data
    public let files: Collection
    
    /// The bucket for file data chunks
    public let chunks: Collection
    
    /// The GridFS bucket name
    public let name: String
    
    /// Drops the GridFS bucket's collections
    public func drop() throws {
        try self.files.drop()
        try self.chunks.drop()
    }
    
    /// Initializes a GridFS `Collection` (bucket) in a given database
    ///
    /// - parameter in: In which database does this GridFS bucket reside
    /// - parameter named: The optional name of this GridFS bucket (by default "fs")
    ///
    /// - throws: When we can't send the request/receive the response, you don't have sufficient permissions or an error occurred or when it can't create it's indexes
    public init(in database: Database, named bucketName: String = "fs") throws {
        files = database["\(bucketName).files"]
        chunks = database["\(bucketName).chunks"]
        name = bucketName
        
        // Make indexes
        try chunks.createIndex(named: "chunksindex", withParameters: .sortedCompound(fields: [("files_id", .ascending), ("n", .ascending)]), .buildInBackground, .unique)
        
        try files.createIndex(named: "filename", withParameters: .sortedCompound(fields: [("uploadDate", .ascending), ("filesindex", .ascending)]), .buildInBackground)
    }
    
    /// Finds the first file matching this ObjectID
    ///
    /// - parameter byID: The hash to look for
    ///
    /// - throws: When we can't send the request/receive the response, you don't have sufficient permissions or an error occurred
    ///
    /// - returns: The resulting file
    public func findOne(byID id: ObjectId) throws -> File? {
        return try self.find("_id" == id).makeIterator().next()
    }
    
    /// Finds using a matching filter
    ///
    /// - parameter filter: The filter to use
    ///
    /// - throws: When we can't send the request/receive the response, you don't have sufficient permissions or an error occurred
    ///
    /// - returns: A cursor pointing to all resulting files
    public func find(_ filter: Query? = nil) throws -> AnyIterator<File> {
        return try Cursor(in: files, where: filter) {
            File(document: $0, chunksCollection: self.chunks, filesCollection: self.files)
        }.find()
    }
    
    /// Removes a file by it's identifier
    public func remove(byId identifier: ObjectId) throws {
        try files.remove("_id" == identifier)
        try chunks.remove("files_id" == identifier)
    }
    
    /// Stores the data in GridFS
    ///
    /// - parameter data: The data to store
    /// - parameter named: The optional filename to use for this data
    /// - parameter withType: The optional MIME type to use for this data
    /// - parameter usingMetadata: The optional metadata to store with this file
    /// - parameter inChunksOf: The amount of bytes to put in one chunk
    ///
    /// TODO: Accept data streams
    public func store(data binary: Bytes, named filename: String? = nil, withType contentType: String? = nil, usingMetadata metadata: BSON.Primitive? = nil, inChunksOf chunkSize: Int = 255_000) throws -> ObjectId {
        guard chunkSize < 15_000_000 else {
            throw MongoError.invalidChunkSize(chunkSize: chunkSize)
        }
        
        var data = binary
        let id = ObjectId()
        let dataSize = data.count
        
        var context = MD5_CTX()
        guard MD5_Init(&context) == 1 else {
            throw MongoError.couldNotHashFile
        }
        
        var insertData: Document = [
            "_id": id,
            "length": dataSize,
            "chunkSize": Int32(chunkSize),
            "uploadDate": Date(timeIntervalSinceNow: 0),
        ]
        
        if let filename = filename {
            insertData["filename"] = filename
        }
        
        if let contentType = contentType {
            insertData["contentType"] = contentType
        }
        
        if let metadata = metadata {
            insertData["metadata"] = metadata
        }
        
        var n = 0
        
        do {
            while !data.isEmpty {
                let smallestMax = min(data.count, chunkSize)
                
                let chunk = Array(data[0..<smallestMax])
                
                guard MD5_Update(&context, chunk, chunk.count) == 1 else {
                    throw MongoError.couldNotHashFile
                }
                
                _ = try chunks.insert(["files_id": id,
                                       "n": n,
                                       "data": Binary(data: chunk, withSubtype: .generic)])
                
                n += 1
                
                data.removeFirst(smallestMax)
            }
            
            var digest = Bytes(repeating: 0, count: Int(MD5_DIGEST_LENGTH))
            
            guard MD5_Final(&digest, &context) == 1 else {
                throw MongoError.couldNotHashFile
            }
            
            insertData["md5"] = digest.toHexString()
            
            _ = try files.insert(insertData)
        } catch {
            try chunks.remove("files_id" == id)
            throw error
        }
        
        return id
    }
    
    /// Stores the data in GridFS
    /// - parameter data: The data to store
    /// - parameter named: The optional filename to use for this data
    /// - parameter withType: The optional MIME type to use for this data
    /// - parameter usingMetadata: The optional metadata to store with this file
    /// - parameter inChunksOf: The amount of bytes to put in one chunk
    public func store(data nsdata: NSData, named filename: String? = nil, withType contentType: String? = nil, usingMetadata metadata: BSON.Primitive? = nil, inChunksOf chunkSize: Int = 255000) throws -> ObjectId {
        return try self.store(data: Array(Data(referencing: nsdata)), named: filename, withType: contentType, usingMetadata: metadata, inChunksOf: chunkSize)
    }
    
    /// A file in GridFS
    public class File: Sequence {
        /// The ObjectID for this file
        public let id: ObjectId
        
        /// The amount of bytes in this file
        public let length: Int
        
        /// The amount of data per chunk
        public let chunkSize: Int32
        
        /// The date on which this file has been uploaded
        public let uploadDate: Date
        
        /// The file's MD5 hash
        public let md5: String
        
        /// The file's name (if any)
        public let filename: String?
        
        /// The file's content-type (MIME) (if any)
        public let contentType: String?
        
        /// The aliases for this file (if any)
        public let aliases: [String]?
        
        /// The metadata for this file (if any)
        public let metadata: BSON.Primitive?
        
        /// The collection where the chunks are stored
        let chunksCollection: Collection
        
        /// The collection where this file is stored
        let filesCollection: Collection
        
        /// Initializes from a file-collection Document
        ///
        /// - parameter document: The `File`'s `Document` that has been found in the files `Collection`
        /// - parameter chunksCollection: The `Collection` where the `File` `Chunk`s are stored
        /// - parameter chunksCollection: The `Collection` where the `File` data is stored
        internal init?(document: Document, chunksCollection: Collection, filesCollection: Collection) {
            guard let id = document["_id"] as? ObjectId,
                let length = Int(document["length"]),
                let chunkSize = Int32(document["chunkSize"]),
                let uploadDate = document["uploadDate"] as? Date,
                let md5 = document["md5"] as? String
                else {
                    return nil
            }
            
            self.chunksCollection = chunksCollection
            self.filesCollection = filesCollection
            
            self.id = id
            self.length = length
            self.chunkSize = chunkSize
            self.uploadDate = uploadDate
            self.md5 = md5
            
            self.filename = document["filename"] as? String
            self.contentType = document["contentType"] as? String
            
            var aliases = [String]()
            
            for alias in [Primitive](document["aliases"]) ?? [] {
                if let alias = alias as? String {
                    aliases.append(alias)
                }
            }
            
            self.aliases = aliases
            self.metadata = document["metadata"]
        }
        
        /// Finds all or specific chunks
        ///
        /// Returns the bytes you selected
        ///
        /// - parameter start: The `Byte` where you start fetching
        /// - parameter end: The `Byte` where you stop fetching
        public func read(from start: Int = 0, to end: Int? = nil) throws -> Bytes {
            let remainderValue = start % Int(self.chunkSize)
            let skipChunks = (start - remainderValue) / Int(self.chunkSize)
            
            var bytesRequested = Int(self.length) - start
            
            if let end = end {
                guard start < end else {
                    throw MongoError.negativeBytesRequested(start: start, end: end)
                }
                
                guard Int(length) >= end else {
                    throw MongoError.tooMuchDataRequested(contains: Int(length), requested: end)
                }
                
                bytesRequested = end - start
            }
            
            let lastByte = start + bytesRequested
            let lastChunkRemainder = lastByte % Int(self.chunkSize)
            
            var endChunk = (lastByte - lastChunkRemainder) / Int(self.chunkSize)
            
            if lastChunkRemainder > 0 {
                endChunk += 1
            }
            
            guard start >= 0 else {
                throw MongoError.negativeDataRequested
            }
            
            let chunkCursor = try Cursor(in: chunksCollection, where: "files_id" == id, transform: {
                Chunk(document: $0, chunksCollection: self.chunksCollection, filesCollection: self.filesCollection)
            }).find(sorting: ["n": .ascending], skipping: skipChunks, limitedTo: endChunk - skipChunks)
            var allData = Bytes()
            
            for chunk in chunkCursor {
                // `if skipChunks == 1` then we need the chunk.n to be 1 too,
                // start counting at 0
                if chunk.n == Int32(skipChunks) {
                    allData.append(contentsOf: chunk.data[(start % Int(self.chunkSize))..<Swift.min(Int(self.chunkSize), chunk.data.count)])
                    
                // if endChunk == 10 then we need the current chunk to be 9
                // start counting at 0
                } else if chunk.n == Int32(endChunk - 1) {
                    let endIndex = lastByte - Int(chunk.n * self.chunkSize)
                    
                    guard endIndex >= 0 else {
                        throw MongoError.tooMuchDataRequested(contains: Int(chunk.n * (self.chunkSize)) + chunk.data.count, requested: end ?? -1)
                    }
                    
                    guard chunk.data.count >= endIndex else {
                        throw MongoError.tooMuchDataRequested(contains: Int((chunk.n - 1) * self.chunkSize) + chunk.data.count, requested: lastByte)
                    }
                    
                    allData.append(contentsOf: chunk.data[0..<endIndex])
                } else if chunk.n < Int32(endChunk - 1) {
                    allData.append(contentsOf: chunk.data)
                } else {
                    throw MongoError.internalInconsistency
                }
            }
            
            return allData
        }
        
        /// Iterates over all chunks of data for this file
        public func makeIterator() -> AnyIterator<Chunk> {
            do {
                return try self.chunked()
            } catch {
                return AnyIterator { nil }
            }
        }
        
        /// Creates an iterator of chunks.
        ///
        /// - throws: Unable to fetch chunks
        public func chunked() throws -> AnyIterator<Chunk> {
            return try Cursor(in: chunksCollection, where: "files_id" == id) {
                    Chunk(document: $0, chunksCollection: self.chunksCollection, filesCollection: self.filesCollection)
                }.find(sorting: ["n": .ascending])
        }
        
        /// A GridFS Byte Chunk that's part of a file
        public class Chunk {
            /// The ID of this chunk
            public let id: ObjectId
            
            /// The ID of the file that this chunk is a part of
            public let filesID: ObjectId
            
            /// Which chunk this is
            public let n: Int32
            
            /// The data for our chunk
            public let data: Bytes
            
            /// The chunk `Collection` which this chunk is stored in
            let chunksCollection: Collection
            
            /// The files `Collection` where our file is stored
            let filesCollection: Collection
            
            /// Initializes with a `Document` found when looking for chunks
            init?(document: Document, chunksCollection: Collection, filesCollection: Collection) {
                guard let id = document["_id"] as? ObjectId,
                    let filesID = document["files_id"] as? ObjectId,
                    let binary = document["data"] as? Binary else {
                        return nil
                }
                
                self.chunksCollection = chunksCollection
                self.filesCollection = filesCollection
                
                self.id = id
                self.filesID = filesID
                self.n = Int32(document["n"]) ?? -1
                self.data = binary.makeBytes()
            }
        }
    }
}

extension GridFS : CustomStringConvertible {
    public var description: String {
        return "MongoKitten.GridFS<\(files.description), \(chunks.description)>"
    }
}