require 'pathname'
require 'rest-client'
require 'sinatra'
require 'commons/builder'
require 'liquid-template-inheritance'

Liquid::Template.file_system = Liquid::LocalFileSystem.new(Pathname.new(__dir__).join('views'), '%s.liquid')

def query_wikidata(sparql_query, config)
  wikidata_client = WikidataClient.new
  wikidata_results_parser = WikidataResultsParser.new(languages: config.languages)
  query = Query.new(
      sparql_query: sparql_query,
      output_dir_pn: Pathname.new(''),
      )
  results = query.run(wikidata_client: wikidata_client, save_query_used: false, save_query_results: false)
  wikidata_results_parser.parse(results)
end

def config_for_country(name)
  data = JSON.parse(RestClient.get("https://raw.githubusercontent.com/everypolitician/#{name}/master/config.json"), symbolize_names: true)
  Config.new data
end

get '/' do
  response = RestClient.get('https://api.github.com/users/everypolitician/repos?per_page=1000',
                            'Accept' => 'application/vnd.github.mercy-preview+json')
  data = JSON.parse(response, symbolize_names: true)
  countries = data.flat_map do |repo|
    if repo[:topics].include? 'commons-data'
      config = JSON.parse(RestClient.get("https://raw.githubusercontent.com/#{repo[:full_name]}/master/config.json"), symbolize_names: true)
      [{
          url: "/country/#{repo[:name]}",
          label: repo[:full_name],
       }]
    else
      []
    end
  end
  erb :index, locals: {'countries': countries}
end

get '/country/:country' do
  config = config_for_country params[:country]
  executives = Executive.list(config).map do |executive|
    {
        url: "/executive/#{params['country']}/#{executive.executive_item_id}?position_ids=#{executive.positions_item_ids.join(',')}",
        label: executive.comment,
    }
  end
  legislatures = Legislature.list(config).map do |legislature|
    {
        url: "/legislature/#{params['country']}/#{legislature.house_item_id}/#{legislature.position_item_id}",
        label: legislature.comment,
    }
  end
  erb :country, locals: {
      'executives': executives,
      'legislatures': legislatures,
  }
end

get '/legislature/:country/:legislature/:position' do
  config = config_for_country params[:country]
  legislature_row = WikidataRow.new({legislature: {value: params['legislature']},
                                     legislaturePost: {value: params['position']}}, config.languages)
  term_rows = Legislature.terms_from_wikidata config, false, [legislature_row]
  terms = term_rows.map do |term_row|
    term = {
        term_item_id: term_row[:term].value,
        comment:      term_row[:termLabel].value,
    }
    term[:start_date] = term_row[:termStart].value if term_row[:termStart]
    term[:end_date] = term_row[:termEnd].value if term_row[:termEnd]
    term[:position_item_id] = term_row[:termSpecificPosition].value if term_row[:termSpecificPosition]
    term
  end
  legislature = Legislature.new house_item_id: params['legislature'], terms: terms, position_item_id: params['position']
  erb :legislature, locals: {
      'params' => params,
      'config' => config,
      'legislature' => legislature,
  }
end

get '/executive/:country/:executive' do
  config = config_for_country params[:country]
  executive = Executive.new executive_item_id: params['executive'], positions: params['position_ids'].split(',').map { |id| {position_item_id: id, branch: nil, comment: nil} }
  wikidata_client = WikidataClient.new
  wikidata_labels = WikidataLabels.new(config: config, wikidata_client: wikidata_client)
  membership_rows = query_wikidata(executive.terms[0].query(config), config)
  membership_data = MembershipData.new(membership_rows, wikidata_labels, 'executive')
  memberships = membership_data.memberships

  persons = membership_data.persons.map { |p| [p[:id], p] }.to_h
  organizations = membership_data.organizations.map { |o| [o[:id], o] }.to_h

  # areas = membership_data.areas.map { |a| [a[:id], a.map { |k,v| [k.to_s, v] }.to_h] }.to_h
  # areas.values.each { |a| a['name'] = config.languages.map { |l| a['name'][:"lang:#{l}"] } }

  memberships = membership_data.memberships
  memberships.each { |m| m[:person] = persons[m[:person_id] ] }
  memberships.each { |m| m[:on_behalf_of] = organizations[m[:on_behalf_of_id] ] }
  # memberships.each { |m| m['area'] = areas[m['area_id'] ] }

  erb :term, locals: {
      'config' => config,
      'executive' => executive,
      'memberships' => memberships,
      'persons' => persons,
      'organizations' => organizations,
  }
end

get '/term/:country/:legislature/:term/:position' do
  config = config_for_country params[:country]

  legislature = Legislature.new house_item_id: params['legislature'], terms: [], position_item_id: params['position']
  term = LegislativeTerm.new legislature: legislature, term_item_id: params['term'], position_item_id: params['position']

  wikidata_client = WikidataClient.new
  wikidata_labels = WikidataLabels.new(config: config, wikidata_client: wikidata_client)
  wikidata_results_parser = WikidataResultsParser.new(languages: config.languages)
  query = Query.new(
      sparql_query: term.query(config),
      output_dir_pn: Pathname.new(''),
  )
  results = query.run(wikidata_client: wikidata_client, save_query_used: false, save_query_results: false)
  membership_rows = wikidata_results_parser.parse(results)

  membership_data = MembershipData.new(membership_rows, wikidata_labels, 'legislative')

  persons = membership_data.persons.map { |p| [p[:id], p] }.to_h
  organizations = membership_data.organizations.map { |o| [o[:id], o] }.to_h

  # areas = membership_data.areas.map { |a| [a[:id], a.map { |k,v| [k.to_s, v] }.to_h] }.to_h
  # areas.values.each { |a| a['name'] = config.languages.map { |l| a['name'][:"lang:#{l}"] } }

  memberships = membership_data.memberships
  memberships.each { |m| m[:person] = persons[m[:person_id] ] }
  memberships.each { |m| m[:on_behalf_of] = organizations[m[:on_behalf_of_id] ] }
  # memberships.each { |m| m['area'] = areas[m['area_id'] ] }

  puts JSON.dump(persons)

  erb :term, locals: {
      'config' => config,
      'term' => term,
      'persons' => persons,
      'organizations' => organizations,
      'memberships' => memberships,
      # 'areas' => areas,
  }

end