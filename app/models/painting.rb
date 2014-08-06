class Painting
  include Mongoid::Document
  field :name, type: String
  field :artist, type: String
  field :year, type: String
end
