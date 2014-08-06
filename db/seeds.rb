# This file should contain all the record creation needed to seed the database with its default values.
# The data can then be loaded with the rake db:seed (or created alongside the db with db:setup).
#
# Examples:
#
#   cities = City.create([{ name: 'Chicago' }, { name: 'Copenhagen' }])
#   Mayor.create(name: 'Emanuel', city: cities.first)

paintings = Painting.create([{name: "The Starry Night", artist: "Van Gogh", year: "1889"}, 
	{name: "Mona Lisa", artist: "Da Vinci", year: "1506"},
	{name: "Squares With Concentric Circles", artist: "Kandinsky", year: "1913"},
	{name: "Vincent Van Gogh", artist: "Gauguin", year: "1888"},
	{name: "Campbell's Soup Cans", artist: "Warhol", year: "1962"},
	{name: "Portrait of a Girl", artist: "Kahlo", year: "1929"},
	{name: "No. 5, 1948", artist: "Pollock", year: "1948"},])