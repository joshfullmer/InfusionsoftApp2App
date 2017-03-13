def initialize_infusionsoft(appname, apikey)

  Infusionsoft.configure do |config|
    config.api_url = "#{appname}.infusionsoft.com"
    config.api_key = apikey
    config.api_logger = Logger.new("#{Rails.root}/log/infusionsoft_api.log")
  end

end

def get_table(tablename,fields=[],criteria={})
  lookup_fields = []
  lookup_fields += fields == [] ? FIELDS["#{tablename}"] : fields
  table = []
  page_index = 0
  while true do
    table_page = Infusionsoft.data_query(tablename,1000,page_index,criteria,lookup_fields)
    table += table_page
    break if table_page.length < 1000
    page_index += 1
  end
  p "#{tablename} table returned #{table.length} records"
  table
end

def create_custom_field(fieldname,headerid=0,tablename='Contact',fieldtype='Text',values=nil)

  #Check to see if custom field exists
  existing_field = Infusionsoft.data_query('DataFormField',1000,0,{ 'Label' => "#{fieldname}" },FIELDS['DataFormField'])
  existing_field.select! { |f| f['FormId'] == CUSTOM_FIELD_FORM_ID.key(tablename)}

  field = {}
  if existing_field.empty?
    if headerid == 0
      tabid = Infusionsoft.data_query('DataFormTab',1000,0,{'FormId' => CUSTOM_FIELD_FORM_ID.key(tablename)},FIELDS['DataFormTab'])[0]['Id']
      headerid = Infusionsoft.data_query('DataFormGroup',1000,0,{'TabId' => tabid},FIELDS['DataFormGroup'])[0]['Id']
    end
    field['Id'] = Infusionsoft.data_add_custom_field(tablename,fieldname,fieldtype,headerid)
    field['Name'] = '_' + Infusionsoft.data_query('DataFormField',1000,0,{ 'Label' => "#{fieldname}", 'FormId' => CUSTOM_FIELD_FORM_ID.key(tablename)},['Name'])[0]['Name']
    Infusionsoft.data_update_custom_field(field['Id'],{ 'Values' => cf['Values'] }) if DATATYPES[DATATYPE_IDS[cf['DataType']]]['hasValues'] == 'yes' && !values
  else
    field['Id'] = existing_field.first['Id']
    field['Name'] = '_' + existing_field.first['Name']
  end
  field

end

def create_user_relationship(source_app_users,dest_app_users)

  relationships = {0=>0}
  source_app_users.each do |src_user|
    dest_app_users.each do |dest_user|
      relationships[src_user['Id']] = dest_user['Id'] if src_user['GlobalUserId'] == dest_user['GlobalUserId'] || src_user['Email'] == dest_user['Email']
    end
  end
  relationships

end

def delete_table(tablename)
  puts "Deleting #{tablename} table..."
  get_table(tablename).each do |row|
    Infusionsoft.data_delete(tablename,row['Id'])
  end
  puts "#{tablename} table deleted."
end