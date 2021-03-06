class App2appController < ApplicationController

  @@source_app_contact_id = "_SourceAppContactID0"    #"_SourceAppContactID"
  @@source_app_company_id = "_SourceAppCompanyID0"
  @@source_app_account_id = "_SourceAppCompanyID"
  @@source_app_action_id = "_SourceAppActionID"
  @@source_app_opportunity_id = "_SourceAppOpportunityID"
  @@source_app_order_id = "_SourceAppOrderID"

  @@subscription_relationship = {}

  $types = ["none"]
  $titles = ["none"]
  $suffixes = ["none"]
  $phonetypes = ["none"]
  $faxtypes = ["none"]

  def start
  end

  def transfer

    #stores source and destination credentials for passing to other methods
    applicationcredentials = {
      src_appname: params[:src_appname],
      src_apikey: params[:src_apikey],
      dest_appname: params[:dest_appname],
      dest_apikey: params[:dest_apikey]
    }

    #transfers contacts if checkbox is checked
    transfer_contacts(applicationcredentials,params[:customfields][:checkbox] == 'true') unless params[:contacts][:checkbox] == 'false'
    transfer_companies(applicationcredentials) unless params[:companies][:checkbox] == 'false'
    transfer_tags(applicationcredentials,params[:companies][:checkbox] == 'true') unless params[:tags][:checkbox] == 'false'
    transfer_contact_actions(applicationcredentials,
                             params[:notes][:checkbox] == 'true',
                             params[:tasks][:checkbox] == 'true',
                             params[:appointments][:checkbox] == 'true') if params[:notes][:checkbox] == 'true' || params[:tasks][:checkbox] == 'true' || params[:appointments][:checkbox] == 'true'
    transfer_products(applicationcredentials) unless params[:products][:checkbox] == 'false'
    transfer_opportunities(applicationcredentials) unless params[:opportunities][:checkbox] == 'false'
    transfer_attachments(applicationcredentials) unless params[:attachments][:checkbox] == 'false'
    transfer_orders(applicationcredentials,params[:subscriptions] == 'true') unless params[:orders][:checkbox] == 'false'
  end

  #adds contacts from source app to destination app
  #does not move custom fields or custom field data

  def transfer_contacts(appdata,customfieldscheck)

    puts "Importing Contacts..."

    #SOURCE APP
    #---------------------------------------

    puts "=> Initializing Source App"
    #initialize source app
    initialize_infusionsoft(appdata[:src_appname], appdata[:src_apikey])

    puts "=> Getting Source Custom Fields"
    #get list of contact custom fields
    #then store the list of names in an array to add to fields for lookup
    source_app_custom_fields = get_table('DataFormField')
    contact_fields = []
    contact_fields = FIELDS['Contact'].map(&:clone)
    source_app_custom_fields.each { |cf| contact_fields.push("_" + cf['Name']) if cf['FormId'] == -1 }

    puts "=> Getting Source Contacts"
    #Option 1
    #________
    #get all contacts from the source app
    all_contacts = get_table('Contact',contact_fields)

    #Option 2
    #________
    #get contacts with specific criteria
    #all_contacts = get_table('Contact',contact_fields,{Id: 282589})
    #all_contacts += (get_table('Contact',contact_fields,{OwnerID: 118786}))

    #reduce list of custom fields to create by detecting which fields have data
    fields_with_data = []
    all_contacts.each { |c| fields_with_data |= c.keys }
    custom_fields_to_import = fields_with_data.grep(/^_/)
    source_app_custom_fields.reject! { |cf| custom_fields_to_import.exclude? '_' + cf['Name']}


    puts "=> Getting Source Opt Outs"
    #get list of opted out emails
    opted_out_emails = get_table('EmailAddStatus').select { |email| OPT_OUT_STATUSES.include? email['Type'] }

    puts "=> Getting Source Lead Sources"
    #get list of Lead Sources and Categories from source app
    source_app_lead_source_categories = get_table('LeadSourceCategory')
    source_app_lead_sources = get_table('LeadSource')

    puts "=> Getting Source Users"
    #get list of users for comparing username to source app
    source_app_users = get_table('User')

    puts "=> Getting Source App Settings"
    #gets lists of app settings for comparing to dest app, stored as arrays
    source_types = Infusionsoft.data_get_app_setting('Contact','optiontypes').split(',')
    source_titles = Infusionsoft.data_get_app_setting('Contact','optiontitles').split(',')
    source_suffixes = Infusionsoft.data_get_app_setting('Contact','optionsuffixes').split(',')
    source_phonetypes = Infusionsoft.data_get_app_setting('Contact','optionphonetypes').split(',')
    source_faxtypes = Infusionsoft.data_get_app_setting('Contact','optionfaxtypes').split(',')


    #DESTINATION APP
    #--------------------------------------

    #INITIALIZATION
    #______________
    puts "=> Initializing Dest App"
    #initialize destination app
    initialize_infusionsoft(appdata[:dest_appname], appdata[:dest_apikey])

    #LEAD SOURCE
    #___________

    puts "=> Importing Lead Sources..."

    #creates Lead Sources and Categories if they don't exist
    #Adds all category names and lead source names to hashes to compare
    dest_app_lead_source_categories = {}
    get_table('LeadSourceCategory').each { |cat| dest_app_lead_source_categories[cat['Id']] = cat['Name'] }

    dest_app_lead_sources = {}
    get_table('LeadSource').each { |src| dest_app_lead_sources[src['Id']] = src['Name'] }

    #adds lead source categories to dest app, and sets the ID of the source app lead source category equal to the category created
    #only adds lead source category if it doesn't already exist in dest app
    category_relationship = {}
    source_app_lead_source_categories.each { |cat|
      category_relationship[cat['Id']] = dest_app_lead_source_categories.key(cat['Name']) || Infusionsoft.data_add('LeadSourceCategory',cat)
    }

    #create empty hash with default relationship of 0 to 0
    lead_source_relationship = {0=>0}
    source_app_lead_sources.each do |src|
      #swaps old category ID with new category ID
      src['LeadSourceCategoryId'] = category_relationship[src['LeadSourceCategoryId']] unless src['LeadSourceCategoryId'] == 0

      #creates lead source if it doesn't exist by the same name
      lead_source_relationship[src['Id']] = dest_app_lead_sources.key(src['Name']) || Infusionsoft.data_add('LeadSource',src)
    end

    #FKID AND CONTACT CUSTOM FIELDS
    #__________________

    puts "=> Importing Custom Fields..."

    #creates Source App Contact and Company ID custom fields if they don't exist
    @@source_app_contact_id = create_custom_field('Source App Contact ID')['Name']
    @@source_app_company_id = create_custom_field('Source App Company ID')['Name']

    #create contact custom fields if the custom fields check is true
    #also maps the source app custom fields to any existing custom fields in the dest app
    rename_mapping = {}

    source_app_custom_fields.each do |cf|
      #checks if app has ANY custom fields; also skips any of type 25, which is unknown, or when it's not a contact custom field
      next if cf.nil? || cf['DataType'] == 25 || cf['FormId'] != -1
      field = create_custom_field(cf['Label'],0,'Contact',DATATYPES[DATATYPE_IDS[cf['DataType']]]['dataType'],cf['Values'])
      rename_mapping['_' + cf['Name']] = field['Name']
    end if customfieldscheck


    #switches the 'Id' key to be 'Source App Contact ID'
    #switches the 'CompanyID' key to be 'Source App Company ID'
    rename_mapping['Id'] = @@source_app_contact_id
    rename_mapping['CompanyID'] = @@source_app_company_id

    #USERS
    #_____
    puts "=> Creating User Relationship"
    #Matches up users based on their 'GlobalUserId' which is the Infusionsoft ID
    users_relationship = create_user_relationship(source_app_users,get_table('User'))

    #APP SETTINGS
    #____________
    puts "=> Generating App Settings Differences"

    #Get differene between source app settings and dest app settings
    $types = source_types - Infusionsoft.data_get_app_setting('Contact','optiontypes').split(',')
    $titles = source_titles - Infusionsoft.data_get_app_setting('Contact','optiontitles').split(',')
    $suffixes = source_suffixes - Infusionsoft.data_get_app_setting('Contact','optionsuffixes').split(',')
    $phonetypes = source_phonetypes - Infusionsoft.data_get_app_setting('Contact','optionphonetypes').split(',')
    $faxtypes = source_faxtypes - Infusionsoft.data_get_app_setting('Contact','optionfaxtypes').split(',')

    #CREATE IMPORT TAG
    #_________________

    puts "=> Creating Import Tag..."

    #check if Category and Tag already exist
    existing_cat_id = Infusionsoft.data_query('ContactGroupCategory',1000,0,{'CategoryName' => 'Application Transfer'},['Id'])
    existing_tag_id = Infusionsoft.data_query('ContactGroup',
                                              1000,
                                              0,
                                              {'GroupCategoryId' => existing_cat_id.first['Id'], 'GroupName' => "Data from #{appdata[:src_appname]}"},
                                              ['Id']) unless existing_cat_id.to_a.empty?

    import_tag_cat_id = existing_cat_id.to_a.empty? ? Infusionsoft.data_add('ContactGroupCategory',{'CategoryName' => 'Application Transfer'}) : existing_cat_id.first['Id']
    import_tag_id = existing_tag_id.to_a.empty? ? Infusionsoft.data_add('ContactGroup',{'GroupCategoryId' => import_tag_cat_id, 'GroupName' => "Data from #{appdata[:src_appname]}"}) : existing_tag_id.first['Id']

    #GET CONTACTS THAT HAVE ALREADY BEEN TRANSFERRED
    #_______________________________________________
    dest_contacts = get_table("Contact",[@@source_app_contact_id],{@@source_app_contact_id => "_%"}).map { |c| c[@@source_app_contact_id]}

    #ADD CONTACTS
    #____________

    puts "=> Adding contacts..."

    #adds each contact in the list of contacts to destination app
    #swaps lead source IDs before import to dest app lead source ID
    #swaps user ID to destination app user ID based on users_relationship matching
    dest_emails = []
    all_contacts.each do |contact|
      next if dest_contacts.include? contact['Id'].to_s #skips importing contacts that have previously been transferred
      contact.keys.each { |k| contact[ rename_mapping[k] ] = contact.delete(k).to_s if rename_mapping[k] }
      contact.delete('AccountId')
      contact['LeadSourceId'] = lead_source_relationship[contact['LeadSourceId']]
      contact['OwnerID'] = users_relationship[contact['OwnerID']] || 0
      contact_id = Infusionsoft.contact_add(contact) unless contact[@@source_app_contact_id] == contact[@@source_app_company_id]
      Infusionsoft.contact_add_to_group(contact_id, import_tag_id) unless contact_id.nil?
      dest_emails |= [contact['Email']]
    end

    puts "=> Opting Out Emails"
    #opt out all emails that were opted out in the source app
    opted_out_emails.each do |email|
      Infusionsoft.email_optout(email, 'Source App Opt Out') if dest_emails.include? email
    end

    puts "Contacts Imported."
  end

  def transfer_companies(appdata)

    puts "Importing Companies..."

    #SOURCE APP
    #-----------------------------------------------------------------------------

    #INITIALIZE INFUSIONSOFT
    #_______________________
    #initializes source app
    initialize_infusionsoft(appdata[:src_appname], appdata[:src_apikey])

    #SOURCE APP DATA
    #_______________
    #Gets source app companies and company custom fields
    puts "=> Getting Source Data"
    source_app_custom_fields = get_table('DataFormField')
    company_fields = []
    company_fields = FIELDS['Company'].map(&:clone)

    source_app_custom_fields.each { |cf| company_fields.push("_" + cf['Name']) if cf['FormId'] == -6 }

    #gets source companies with custom fields.
    source_companies = get_table('Company',company_fields)

    #gets source contacts with source companyID to match up
    source_contacts = get_table('Contact')

    #skip importing custom fields where companies don't have any data
    fields_with_data = []
    source_companies.each { |c| fields_with_data |= c.keys }
    custom_fields_to_import = fields_with_data.grep(/^_/)
    source_app_custom_fields.reject! { |cf| custom_fields_to_import.exclude? '_' + cf['Name']}

    #DESTINATION APP
    #-----------------------------------------------------------------------------

    #INITIALIZE INFUSIONSOFT
    #_______________________
    #initializes destination app
    initialize_infusionsoft(appdata[:dest_appname], appdata[:dest_apikey])

    #CREATE COMPANY CUSTOM FIELDS
    #____________________
    #get tab id for first company custom field tab, then get header tab using that tab id
    puts "=> Creating custom fields"

    #create company custom fields if they don't exist, and store the rename mapping in a hash for use later
    rename_mapping = {}
    source_app_custom_fields.each do |cf|
      next if cf['FormId'] != -6
      field = create_custom_field(cf['Label'],0,'Company',DATATYPES[DATATYPE_IDS[cf['DataType']]]['dataType'],cf['Values'])
      rename_mapping['_' + cf['Name']] = field['Name']
    end

    #RENAME COMPANY FIELDS TO MATCH CUSTOM FIELDS
    #____________________________________________
    @@source_app_account_id = create_custom_field('Source App Company ID',0,'Company','Text')['Name']
    rename_mapping['Id'] = @@source_app_account_id

    #GET COMPANIES THAT HAVE ALREADY BEEN IMPORTED
    #_____________________________________________
    dest_companies = get_table("Company",[@@source_app_account_id],{@@source_app_account_id => "_%"}).map { |c| c[@@source_app_account_id]}

    #IMPORT COMPANIES
    #________________
    puts "=> Importing Company records"
    company_relationship = {0=>0}
    source_companies.each do |comp|
      next if dest_companies.include? comp['Id'].to_s #skips importing contacts that have previously been transferred
      comp.keys.each { |k| comp[ rename_mapping[k] ] = comp.delete(k).to_s if rename_mapping[k] } #rename fields to match those in dest app
      company_relationship[comp['CompanyID']] = Infusionsoft.data_add('Company',comp) unless comp.nil?
    end

    #ASSIGN CONTACTS TO COMPANIES
    #____________________________
    puts "=> Assigning Contacts to Companies"
    contact_ids_relationship = {0=>0}
    get_table('Contact',[@@source_app_contact_id,'Id']).each do |cont|
      contact_ids_relationship[cont[@@source_app_contact_id].to_i] = cont['Id'] unless cont[@@source_app_contact_id].nil? || cont.nil?
    end

    source_contacts.each do |cont|
      next if cont['AccountId'] == 0 || cont['AccountId'] == cont['Id'] || company_relationship[cont['AccountId']].nil?
      Infusionsoft.data_update('Contact',contact_ids_relationship[cont['Id']],{'AccountId' => company_relationship[cont['AccountId'].to_i]})
    end

    puts "Companies Imported."
  end

  #creates tags in destination app
  #only creates tags that don't have an exact match, matching both name and category

  def transfer_tags(appdata,companytagcheck)

    puts "Importing Tags..."

    #SOURCE APP
    #-----------------------------------------------------------------------------

    #INITIALIZE INFUSIONSOFT
    #_______________________
    #initializes source app
    puts "=> Initializing"
    initialize_infusionsoft(appdata[:src_appname], appdata[:src_apikey])

    #SOURCE APP DATA
    #_______________
    #Gets source app tags and tag categories
    puts "=> Getting Source App Data"
    source_tag_categories = get_table('ContactGroupCategory')
    source_tags = get_table('ContactGroup')

    #gets tag assignments
    source_tag_assignments = get_table('ContactGroupAssign')

    tags_on_contacts = []
    get_table('Contact').each { |c| tags_on_contacts |= c['Groups'].split(",") unless c['Groups'].nil? }
    source_tags.reject! { |t| tags_on_contacts.exclude? t['Id'].to_s}


    #DESTINATION APP
    #-----------------------------------------------------------------------------

    #INITIALIZE INFUSIONSOFT
    #_______________________
    #initializes destination app
    initialize_infusionsoft(appdata[:dest_appname], appdata[:dest_apikey])

    #DEST APP DATA
    #_____________
    #gets tags and tag categories that already exist in destination app
    puts "=> Getting Dest App Data"
    dest_tag_categories = {}
    get_table('ContactGroupCategory').each { |cat| dest_tag_categories[cat['Id']] = cat['CategoryName'] }

    dest_tags = {}
    get_table('ContactGroup').each { |tag| dest_tags[tag['Id']] = tag['GroupName'] }

    #creates ID relationships for contacts and companies
    dest_contacts = {}
    get_table('Contact',['Id',@@source_app_contact_id]).each { |contact| dest_contacts[contact[@@source_app_contact_id].to_i] = contact['Id'] }

    dest_companies = {}
    get_table('Company',['Id',@@source_app_account_id]).each { |company| dest_companies[company[@@source_app_account_id].to_i] = company['Id'] } unless params[:companies][:checkbox] == 'false'


    #CREATE TAGS AND CATEGORIES
    #__________________________
    #Create Categories and tags if they don't already exist
    puts "=> Creating Categories"
    category_relationship = {}
    source_tag_categories.each do |cat|
      category_relationship[cat['Id']] = dest_tag_categories.key(cat['CategoryName']) || Infusionsoft.data_add('ContactGroupCategory',cat)
    end

    puts "=> Creating Tags"
    tag_relationship = {}
    source_tags.each do |tag|
      tag['GroupCategoryId'] = category_relationship[tag['GroupCategoryId']] unless tag['GroupCategoryId'] == 0
      tag_relationship[tag['Id']] = dest_tags.key(tag['GroupName']) || Infusionsoft.data_add('ContactGroup',tag)
    end

    #ADD TAGS TO CONTACTS & COMPANIES
    #________________________________
    #adds tags to contacts using the ContactGroupAssign table from the source app
    puts "=> Applying Tags"
    source_tag_assignments.each do |contact|
      next if dest_contacts[contact['ContactId']].nil? && dest_companies[contact['Contact.CompanyID']].nil?
      contact['GroupId'] = tag_relationship[contact['GroupId']]
      dest_contacts[contact['ContactId']].nil? ? Infusionsoft.contact_add_to_group(dest_companies[contact['Contact.CompanyID']], contact['GroupId']) : Infusionsoft.contact_add_to_group(dest_contacts[contact['ContactId']], contact['GroupId'])
    end

    puts "Tags Imported."
  end

  def transfer_contact_actions(appdata,notescheck,taskscheck,appointmentscheck)

    puts "Importing Notes/Tasks/Appointments..."

    #SOURCE APP
    #-----------------------------------------------------------------------------

    puts "=> Getting Source Data"
    #INITIALIZE INFUSIONSOFT
    #_______________________
    #initializes source app
    initialize_infusionsoft(appdata[:src_appname], appdata[:src_apikey])

    #SOURCE APP DATA
    #_______________
    #get contact action table and user id table
    source_contact_actions = get_table('ContactAction')
    source_app_users = get_table('User')

    #DESTINATION APP
    #-----------------------------------------------------------------------------

    #INITIALIZE INFUSIONSOFT
    #_______________________
    #initializes destination app
    initialize_infusionsoft(appdata[:dest_appname], appdata[:dest_apikey])

    puts "=> Getting Destination Data"
    #DEST APP DATA
    #_____________
    #get contact and source ids
    #get user relationship - Hash where key is dest ID and value is source ID
    contact_ids_relationship = {}
    get_table('Contact',['Id',@@source_app_contact_id],{@@source_app_contact_id => "_%"}).each { |id| contact_ids_relationship[id[@@source_app_contact_id].to_i] = id['Id'] }
    users_relationship = create_user_relationship(source_app_users,get_table('User'))

    puts "=> Creating Custom Field for FKID"
    #CREATE CUSTOM FIELD FOR FKID
    #____________________________
    @@source_app_action_id = create_custom_field('Source App Action ID',0,'ContactAction','Text')['Name']

    #GET ACTIONS THAT HAVE ALREADY BEEN TRANSFERRED
    #_______________________________________________
    dest_actions = get_table('ContactAction',[@@source_app_action_id],{@@source_app_action_id => "_%"}).map { |c| c[@@source_app_action_id]}

    puts "=> Transferring Contact Actions"
    #TRANSFER TASKS NOTES APPTS
    #__________________________
    #checks for the parameter if each type should be transferred
    transfer_check = {
      'Note' => notescheck,
      'Task' => taskscheck,
      'Appointment' => appointmentscheck
    }
    default_user_id = Infusionsoft.data_get_app_setting('Templates','defuserid')
    source_contact_actions.each do |action|
      #skips the action if it doesn't have a contact, if it has already been transferred, or if it's not checked on the form
      next if contact_ids_relationship[action['ContactId']].nil? || dest_actions.include?(action['Id'].to_s) || !transfer_check[action['ObjectType']]
      action.except!('OpportunityId')
      action[@@source_app_action_id] = action['Id'].to_s
      action['ContactId'] = contact_ids_relationship[action['ContactId']]
      action['UserID'] = users_relationship[action['UserID']] || default_user_id
      action['ActionDescription'].prepend("[Task] ") if action['ObjectType'] == 'Task' && !action['ActionDescription'].nil?
      Infusionsoft.data_add('ContactAction',action)
    end

    puts "Notes/Tasks/Appointments Imported."
  end

  #creates products in destination app
  #only creates products that don't have an exact match, matching by product name

  def transfer_products(appdata)

    puts "Importing Products..."

    #SOURCE APP
    #-----------------------------------------------------------------------------

    #INITIALIZE INFUSIONSOFT
    #_______________________
    #initializes source app
    initialize_infusionsoft(appdata[:src_appname], appdata[:src_apikey])

    puts "=> Getting Source Data"
    #SOURCE APP DATA
    #_______________
    #get products, categories, and category assignments
    source_products = get_table('Product')
    source_product_categories = get_table('ProductCategory')
    source_category_assign = get_table('ProductCategoryAssign')
    source_subscription_plans = get_table('SubscriptionPlan')


    #DESTINATION APP
    #-----------------------------------------------------------------------------

    #INITIALIZE INFUSIONSOFT
    #_______________________
    #initializes destination app
    initialize_infusionsoft(appdata[:dest_appname], appdata[:dest_apikey])

    puts "=> Getting Destination App Data"
    #DEST APP DATA
    #_____________
    #get destination app products and categories to compare against source data, and stores them in hashes
    dest_products = {}
    get_table('Product').each { |prod| dest_products[prod['Id']] = prod['ProductName'] }

    dest_product_categories = {}
    get_table('ProductCategory').each { |cat| dest_product_categories[cat['Id']] = cat['CategoryDisplayName'] }

    dest_subscription_plans = get_table('SubscriptionPlan')

    #CREATE SUBSCRIPTIONS, PRODUCTS, AND CATEGORIES
    #______________________________
    #create products and categories if they don't exist by name in destination app
    puts "=> Importing Products"
    product_relationships = {}
    source_products.each do |prod|
      product_relationships[prod['Id']] = dest_products.key(prod['ProductName']) || Infusionsoft.data_add('Product',prod)
    end

    puts "=> Importing Subscription Plans"
    source_subscription_plans.each do |sub|
      do_not_import = false
      dest_subscription_plans.each do |plan|
        do_not_import = sub['PlanPrice'] == plan['PlanPrice'] && sub['NumberOfCycles'] == plan['NumberOfCycles'] && product_relationships[sub['ProductId']] == plan['ProductId']
        @@subscription_relationship[sub['Id']] = plan['Id'] if do_not_import
        break if do_not_import
      end
      sub['ProductId'] = product_relationships[sub['ProductId']]
      do_not_import ||= sub['ProductId'].nil?
      @@subscription_relationship[sub['Id']] = Infusionsoft.data_add('SubscriptionPlan',sub) unless do_not_import
    end

    puts "=> Importing Product Categories"
    category_relationships = {}
    source_product_categories.each do |cat|
      category_relationships[cat['Id']] = dest_product_categories.key(cat['CategoryDisplayName']) || Infusionsoft.data_add('ProductCategory',cat)
    end

    #ATTACH PRODUCTS AND CATEGORIES
    #______________________________
    #add assignments to ProductCategoryAssign, matching Ids based on previously created relationship hashes
    puts "=> Attaching Products to Categories"
    dest_category_assign = get_table('ProductCategoryAssign')
    source_category_assign.each do |assign|
      do_not_import = false
      dest_category_assign.each do |cat|
        do_not_import = product_relationships[assign['ProductId']] == cat['ProductId'] && category_relationships[assign['ProductCategoryId']] == cat['ProductCategoryId']
        break if do_not_import
      end
      Infusionsoft.data_add('ProductCategoryAssign',{'ProductId' => product_relationships[assign['ProductId']], 'ProductCategoryId' => category_relationships[assign['ProductCategoryId']]}) unless do_not_import
    end

    puts "Products Imported."
  end

  #opportunity stages cannot be created by the API, so they will need to be replicated before the transfer
  #if they are not replicated, the opportunities will be added to the New stage, or the default stage.

  def transfer_opportunities(appdata)

    puts "Importing Opportunities..."

    #SOURCE APP
    #-----------------------------------------------------------------------------

    #INITIALIZE INFUSIONSOFT
    #_______________________
    #initializes source app
    initialize_infusionsoft(appdata[:src_appname], appdata[:src_apikey])

    #SOURCE APP DATA
    #_______________
    #get opportunities, custom fields, product interests, and product interest bundles
    source_app_custom_fields = get_table('DataFormField')
    opportunity_fields = []
    opportunity_fields = FIELDS['Lead'].map(&:clone)

    source_app_custom_fields.each { |cf| opportunity_fields.push("_" + cf['Name']) if cf['FormId'] == -4 }

    #gets source companies with custom fields.
    source_opportunities = get_table('Lead',opportunity_fields)

    #get source products, product interests, and interest bundles
    source_products = {}
    get_table('Product').each { |product| source_products[product['ProductName']] = product['Id'] }
    source_interests = get_table('ProductInterest')
    source_bundles = get_table('ProductInterestBundle')

    #get source app users for owner assignment
    source_app_users = get_table('User')

    #get source app opportunity stages to match to destination app stages
    source_app_stages = get_table('Stage')

    #DESTINATION APP
    #-----------------------------------------------------------------------------

    #INITIALIZE INFUSIONSOFT
    #_______________________
    #initializes destination app
    initialize_infusionsoft(appdata[:dest_appname], appdata[:dest_apikey])

    #DEST APP DATA
    #_____________
    #get contacts and companies from source app
    dest_contacts = {}
    get_table('Contact',['Id',@@source_app_contact_id]).each { |contact| dest_contacts[contact['Id']] = contact[@@source_app_contact_id].to_i }

    dest_companies = {}
    get_table('Company',['Id',@@source_app_account_id]).each { |company| dest_companies[company['Id']] = company[@@source_app_account_id].to_i } unless params[:companies][:checkbox] == 'false'

    dest_default_stage = Infusionsoft.data_get_app_setting('Opportunity','defaultstage')

    #CREATE OPPORTUNITY CUSTOM FIELDS
    #____________________
    #get tab id for first opportunity custom field tab, then get header tab using that tab id
    custom_field_tab_id = Infusionsoft.data_query('DataFormTab',1000,0,{'FormId' => -4},['Id'])[0]['Id']
    custom_field_header_id = Infusionsoft.data_query('DataFormGroup',1000,0,{'TabId' => custom_field_tab_id},['Id'])[0]['Id']

    #create opportunity custom fields if they don't exist, and store the rename mapping in a hash for use later
    rename_mapping = {}
    source_app_custom_fields.each do |customfield|
      if customfield['FormId'] == -4
        field = create_custom_field(customfield['Label'],custom_field_header_id,'Opportunity',DATATYPES[DATATYPE_IDS[customfield['DataType']]]['dataType'])
        rename_mapping['_' + customfield['Name']] = field['Name']
        Infusionsoft.data_update_custom_field(field['Id'],{ 'Values' => customfield['Values'] }) if DATATYPES[DATATYPE_IDS[customfield['DataType']]]['hasValues'] == 'yes'  && customfield['Values'] != nil
      end
    end

    #RENAME OPPORTUNITY FIELDS TO MATCH CUSTOM FIELDS
    #____________________________________________
    @@source_app_opportunity_id = create_custom_field('Source App Opportunity ID',custom_field_header_id,'Opportunity','Text')['Name']
    rename_mapping['Id'] = @@source_app_opportunity_id
    source_opportunities.each_with_index do |item, pos|
      source_opportunities[pos].keys.each { |k| source_opportunities[pos][ rename_mapping[k] ] = source_opportunities[pos].delete(k).to_s if rename_mapping[k] }
    end

    #CREATE USER RELATIONSHIP
    #________________________
    users_relationship = create_user_relationship(source_app_users,get_table('User'))

    #CREATE OPPORTUNITY STAGE RELATIONSHIP
    #_____________________________________
    #takes source app stages, and matches those stages to destination app if the name and stage order are exactly the same.
    dest_stages = {}
    get_table('Stage').each do |dest_stage|
      source_app_stages.each do |src_stage|
        dest_stages[src_stage['Id']] = dest_stage['Id'] if src_stage['StageName'] == dest_stage['StageName'] && src_stage['StageOrder'] == dest_stage['StageOrder']
      end
    end

    #GET CURRENT OPPS AND CREATE RELATIONSHIP
    #________________________________________
    dest_opportunities = {}
    current_dest_opps = []
    get_table("Lead",[@@source_app_opportunity_id,'Id'],{@@source_app_opportunity_id => "_%"}).each do |opp|
      dest_opportunities[opp[@@source_app_opportunity_id].to_i] = opp['Id']
      current_dest_opps.push(opp[@@source_app_opportunity_id])
    end

    #IMPORT OPPORTUNITIES
    #____________________
    #attaches opps to contacts or companies
    source_opportunities.each do |opp|
      next if (current_dest_opps.include?(opp[@@source_app_opportunity_id]) || (dest_contacts.key(opp['ContactID']).nil? && dest_companies.key(opp['ContactID']).nil?))
      opp['ContactID'] = dest_contacts.key(opp['ContactID']) || dest_companies.key(opp['ContactID'])
      opp['StageID'] = dest_stages[opp['StageID']] || dest_default_stage
      opp['UserID'] = users_relationship[opp['UserID']] || 0
      dest_opportunities[opp[@@source_app_opportunity_id].to_i] = Infusionsoft.data_add('Lead',opp)
    end

    #IMPORT PRODUCT BUNDLES AND INTERESTS
    #______________________
    #create relationship between source and dest products
    dest_products = {}
    get_table('Product').each { |product| dest_products[source_products[product['ProductName']]] = product['Id'] }

    dest_bundles = {}
    get_table('ProductInterestBundle').each { |bundle| dest_bundles[bundle['BundleName']] = bundle['Id'] }

    bundles_relationship = {}
    source_bundles.each { |bundle| bundles_relationship[bundle['Id']] = dest_bundles[bundle['BundleName']] || Infusionsoft.data_add('ProductInterestBundle',bundle) }

    source_interests.each do |interest|
      interest['ObjectId'] = bundles_relationship[interest['ObjectId']] if interest['ObjType'] == 'Bundle'
      interest['ObjectId'] = dest_opportunities[interest['ObjectId']] if interest['ObjType'] == 'Opportunity'
      interest['ProductId'] == 0 ? interest['SubscriptionPlanId'] = @@subscription_relationship[interest['SubscriptionPlanId']] : interest['ProductId'] = dest_products[interest['ProductId']]
      Infusionsoft.data_add('ProductInterest',interest) unless interest['ObjType'] == 'Action' || interest['ProductId'].nil?
    end unless source_interests.empty?

    puts "Opportunities Imported."
  end

  def transfer_attachments(appdata)
    puts "Importing attachments..."

    #SOURCE APP
    #-----------------------------------------------------------------------------

    #INITIALIZE INFUSIONSOFT
    #_______________________
    #initializes source app
    initialize_infusionsoft(appdata[:src_appname], appdata[:src_apikey])

    #GET SOURCE DATA
    #_______________
    source_file_table = get_table('FileBox')

    #gets a list of user IDs to ignore from the FileBox table, so we only import contact files and not user files
    users = get_table('User').map { |user| user['Id'] }

    #TRANSFER FILES
    #______________
    #goes through each of the files in the source app, and adds it individually to the destination app, keeping the file in memory instead of writing it
    source_file_table.each do |file|
      #moves to the next file if:
      #file is not attached to any contact OR file is attached to a user
      #file is not a supported filetype --- TODO get full list of unsupported types
      next if (file['ContactId'] == 0) || (users.include? file['ContactId']) || (SUPPORTED_FILE_TYPES.exclude? file['Extension'])

      #get the file from the source app
      initialize_infusionsoft(appdata[:src_appname], appdata[:src_apikey])
      file_data = Infusionsoft.file_get(file['Id'])

      #get the contact that the file is attached to (skip if contact doesn't exist)
      initialize_infusionsoft(appdata[:dest_appname], appdata[:dest_apikey])
      contact = Infusionsoft.data_query('Contact',1000,0,{@@source_app_contact_id => file['ContactId']},['Id'])
      next if contact == [] || file['FileName'].nil?

      contact_files = get_table("FileBox",['FileName'],{"ContactId" => contact.first['Id']}).map { |f| f['FileName']}

      #upload file
      puts "File ID: #{file['Id']}"
      puts "Filename: #{file['FileName']}"
      Infusionsoft.file_upload(contact.first['Id'],file['FileName'].downcase,file_data) unless contact_files.include? file['FileName'].downcase
    end

    puts "Attachments Imported."
  end

  def transfer_orders(appdata,subscriptioncheck=false)
    puts "Importing orders..."

    #INITIALIZE INFUSIONSOFT
    #_______________________
    #initializes source app
    initialize_infusionsoft(appdata[:src_appname], appdata[:src_apikey])

    #GET SOURCE DATA
    #_______________
    puts "=> Getting Source Data..."

    #get Job, Invoice, InvoiceItem, and InvoicePayment tables
    source_jobs = get_table('Job')
    #source_jobs = get_table('Job',[],{Id: 6})
    source_invoices = get_table('Invoice')
    source_invoice_items = get_table('InvoiceItem')
    source_invoice_payments = get_table('InvoicePayment')
    source_payments = get_table('Payment')
    source_payment_plans = get_table('PayPlan')
    source_payment_plan_items = get_table('PayPlanItem')

    source_products = {}
    get_table('Product').each { |product| source_products[product['ProductName']] = product['Id'] }

    #DESTINATION APP
    #-----------------------------------------------------------------------------

    #INITIALIZE INFUSIONSOFT
    #_______________________
    #initializes destination app
    initialize_infusionsoft(appdata[:dest_appname], appdata[:dest_apikey])

    #GET DEST DATA
    #_____________
    puts "=> Getting Destination Data..."

    #get contact relationship
    contact_ids_relationship = {}
    get_table('Contact',['Id',@@source_app_contact_id]).each { |contact| contact_ids_relationship[contact[@@source_app_contact_id].to_i] = contact['Id'] }

    #create historical Job > Invoice relationship
    historical_job_invoice_relationship = {}
    source_invoices.each { |invoice| historical_job_invoice_relationship[invoice['JobId']] = invoice['Id'] }

    #CREATE BLANK ORDERS
    #___________________
    puts "=> Creating Blank Orders..."

    #create custom field for orders
    @@source_app_order_id = create_custom_field('Source App Order ID',0,'Job','Text')['Name']

    #get orders that already exist
    dest_orders = get_table('Job',[@@source_app_order_id],{@@source_app_order_id => '_%'}).map { |j| j[@@source_app_order_id].to_i }
    dest_order_relationship = {}
    get_table('Job',[@@source_app_order_id,'Id'],{@@source_app_order_id => '_%'}).each { |j| dest_order_relationship[j[@@source_app_order_id]] = j['Id']}

    #creates blank orders and stores relationship between the created Invoice and the historical invoice
    invoice_relationship = {}
    source_jobs.each do |job|
      if dest_orders.include? job['Id']
        invoice_relationship[historical_job_invoice_relationship[job['Id']].to_i] = dest_order_relationship[job['Id']]
        next
      end
      next unless (contact_ids_relationship[job['ContactId']]) || ((job['JobRecurringId'] == 0) && subscriptioncheck) #skips orders attached to users and subscription orders
      invoice_relationship[historical_job_invoice_relationship[job['Id']].to_i] = Infusionsoft.invoice_create_blank_order(contact_ids_relationship[job['ContactId']],job['JobTitle'],job['DueDate'],0,0)
      Infusionsoft.data_update('Job',invoice_relationship[historical_job_invoice_relationship[job['Id']].to_i],{@@source_app_order_id => job['Id'].to_s})
    end

    #CREATE ORDER ITEMS
    #__________________
    puts "=> Creating Order Items..."

    #create relationship between invoices and purchased products
    historical_invoice_product_relationship = {}
    source_invoices.each do |invoice|
      next if invoice['ProductSold'].nil?
      historical_invoice_product_relationship[invoice['Id']] = invoice['ProductSold'].split(",").map(&:to_i)
    end

    #create product relationship based on exact product name
    dest_products = {}
    get_table('Product').each do |product|
      next if source_products[product['ProductName']].nil?
      dest_products[source_products[product['ProductName']]] = product['Id']
    end

    #create invoice items
    source_invoice_items.each do |item|
      #invoice ID
      invoice_id = invoice_relationship[item['InvoiceId']]
      next if invoice_id.nil? #skips invoices that weren't created, because they didn't have a contact to attach to, or if they were subscription orders

      #product ID
      historical_invoice_product_relationship[item['InvoiceId']].nil? ? product_id = 0 : product_id = dest_products[historical_invoice_product_relationship[item['InvoiceId']].shift]
      product_id.nil? ? product_type = 0 : product_type = 4
      product_id = 0 if product_id.nil?

      #product types
      product_type = 1 if /^Shipping/.match(item['Description']) && product_id == 0
      product_type = 2 if /^Sales Tax/.match(item['Description']) && product_id == 0

      #quantity
      match = /\(Qty (\d+)\)/.match(item['Description'])
      match.nil? ? quantity = 1 : quantity = match.captures.first.to_i

      #price
      price = item['InvoiceAmt'].to_f / quantity

      #description
      description = item['Description']

      #create invoice item
      Infusionsoft.invoice_add_order_item(invoice_id,product_id,product_type,price.to_f,quantity,description,'')
    end

    #CREATE ORDER PAYMENTS
    #_____________________
    puts "=> Creating Order Payments"

    #creates relationship between InvoicePaymentID and PaymentID
    invoice_payment_relationship = {}
    source_invoice_payments.each { |payment| invoice_payment_relationship[payment['PaymentId']] = payment['Id'] }

    #create relationships for invoice_payment and payment tables, to match PayType and PayNote
    types = {}
    notes = {}
    source_payments.each do |payment|
      types[invoice_payment_relationship[payment['Id']]] = payment['PayType']
      notes[invoice_payment_relationship[payment['Id']]] = payment['PayNote']
    end

    source_invoice_payments.each do |payment|
      #invoice ID
      invoice_id = invoice_relationship[payment['InvoiceId']]
      next if invoice_id.nil? #skips invoices that weren't created, because they didn't have a contact to attach to, or if they were subscription orders

      #amount
      amount = payment['Amt']

      #date
      date = payment['PayDate']

      #type
      type = types[payment['Id']] || ''

      #description
      description = notes[payment['Id']] || ''

      #create manual payments
      Infusionsoft.invoice_add_manual_payment(invoice_id,amount,date,type,description,false)
    end

    #CREATE ORDER PAYMENT PLANS
    #__________________________
    puts "=> Creating Order Payment Plans..."

    #gets dest app settings for retries
    days_between_retry = Infusionsoft.data_get_app_setting('Order','defaultnumdaysbetween').to_i
    max_retry = Infusionsoft.data_get_app_setting('Order','defaultmaxretry').to_i

    #gets number of payments for each payplan and adds it to hash
    #hash is {PayPlanId => NumberOfPayPlanItems}
    #also stores the days between payments for those in the same payplan
    last_pay_plan_id = 0
    last_due_date = DateTime.new

    pay_plan_item_numbers = Hash.new(0)
    days_between_payments_relationship = {}
    source_payment_plan_items.each do |item|
      next unless item['PayPlanId'] == last_pay_plan_id
      pay_plan_item_numbers[item['PayPlanId']] += 1
      days_between_payments_relationship[item['PayPlanId']] = (item['DateDue'].to_date - last_due_date.to_date).to_i if item['PayPlanId'] == last_pay_plan_id
      last_pay_plan_id = item['PayPlanId']
      last_due_date = item['DateDue']
    end

    source_payment_plans.each do |plan|
      #invoice id
      invoice_id = invoice_relationship[plan['InvoiceId']]
      next if invoice_id.nil? #skips invoices that weren't created, because they didn't have a contact to attach to, or if they were subscription orders

      #initial payment amount
      initial_payment_amount = plan['FirstPayAmt']

      #initial payment date
      initial_payment_date = plan['InitDate'] || plan['StartDate']

      #plan start date
      plan_start_date = plan['StartDate']

      #number of payments
      number_of_payments = pay_plan_item_numbers[plan['Id']]
      next if number_of_payments >= 1

      #days between payments
      days_between_payments = days_between_payments_relationship[plan['Id']]
      days_between_payments = 30 if days_between_payments.nil?

      Infusionsoft.invoice_add_payment_plan(invoice_id,false,0,0,days_between_retry,max_retry,initial_payment_amount,initial_payment_date,plan_start_date,number_of_payments,days_between_payments)
    end

    puts "Orders Imported."
  end
end
