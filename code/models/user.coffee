bcrypt = require 'bcrypt'
mongoose = require 'mongoose'
Schema = mongoose.Schema

userSchema = new Schema
  apikey: {type: String, unique: true}
  shortname: {type: String, unique: true}
  created: {type: Date, default: Date.now}

  # XXX these fields can be removed next
  isstaff: Boolean

userSchema.methods.objectify = ->
  result = @toObject()
  delete result._id
  delete result.password # XXX until migration script removes password from mongo database
  return result

module.exports = mongoose.model 'User', userSchema
