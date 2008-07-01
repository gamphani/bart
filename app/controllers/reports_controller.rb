class ReportsController < ApplicationController

	before_filter :check_refresh	
	caches_page :cohort, :virtual_art_register, :missed_appointments, :defaulters, 
              :height_weight_by_user, :monthly_drug_quantities, :survival_analysis
           
	# delete cache report if ?refresh appended to url
	def check_refresh
		expire_page :action => action_name unless params[:refresh].nil? 
	end

  def index
    redirect_to :action => "select"
  end
  # Example report code created with Priscilla
  def height_weight_by_user
    @height_weight_encounters = Hash.new(0)
    EncounterType.find_by_name("Height/Weight").encounters.collect{|e|@height_weight_encounters[e.provider.name] += 1}
  end


  def self.sample_weight_counter
    total = 0
    return Patient.find(:all)[10..20].collect{|patient| 
      weight_observations = patient.observations.find_by_concept_name("Weight")
      unless weight_observations.first.nil?
        weight_observation_date = weight_observations.first.obs_datetime
        total += 1 if weight_observation_date > Date.new(2007,1,1).to_time
        if weight_observation_date > Date.new(2007,1,1).to_time
          weight_observation_date
        else
          "not match #{weight_observations.first.obs_datetime.to_s}"
        end
      end
    }
  end
  
  def select_cohort

    # this action sets up the form that lists all of the available quarters
    # after selecting one it sends it to the cohort action below
  
    #change start date to be the earliest observation in the database (this is on x4k's computer but not in svn)
    #@start_date = Date.new(2003,2,2)
    @start_date = Encounter.find(:first, :order => 'encounter_datetime', :conditions => 'encounter_datetime is not NULL and encounter_datetime <> \'0000-00-00\'').encounter_datetime
    @end_date = Date.today
    if params[:id]
			params[:id] = params[:id].sub(/\s/, "+")
			redirect_to "/reports/cohort/#{params[:id]}" and return 
    end

    render :layout => "application" #this forces the default application layout to be used which gives us the touchscreen toolkit
  end
  
  def set_cohort_date_range
    if params[:start_year].nil? or params[:end_year].nil?
      @needs_date_picker = true
      day=Array.new(31){|d|d + 1 } 
      unknown=Array.new
      unknown[0]= "Unknown" 
      days_with_unknown = day<< "Unknown"
      @days = [""].concat day

      @monthOptions = "<option>" "" "</option>"
  1.upto(12){ |number| 
       @monthOptions += "<option value = '" + number.to_s + "'>" + Date::MONTHNAMES[number] + "</option>"
      }
      @monthOptions << "<option>" "Unknown" "</option>"

      @min_date = Encounter.find(:first, :order => 'encounter_datetime').encounter_datetime.to_date 
      render :layout => "application" 
    else
      start_date = "#{params[:start_year]}-#{params[:start_month]}-#{params[:start_day]}"
      end_date = "#{params[:end_year]}-#{params[:end_month]}-#{params[:end_day]}"
      redirect_to :action => "cohort", :id => params[:id], :start_date => start_date, :end_date => end_date
    end
  end

  def cohort
    @start_time = Time.new
    @messages = []
 
    redirect_to :action => 'select_cohort' and return if params[:id].nil?
    (@quarter_start, @quarter_end) = Report.cohort_date_range(params[:id])  

    @quarter_start = Encounter.find(:first, :order => 'encounter_datetime').encounter_datetime if @quarter_start.nil?
		@quarter_end = Date.today if @quarter_end.nil?
	
		Encounter.cache_encounter_regimen_names if Encounter.dispensation_encounter_regimen_names.blank?    

    @cohort_values = Patient.empty_cohort_data_hash
    @patients_with_visits_or_initiation_in_cohort = ActiveRecord::Base.connection.select_all("
SELECT DISTINCT patient.patient_id 
FROM patient
INNER JOIN encounter ON encounter.patient_id = patient.patient_id 
INNER JOIN (
   SELECT satisfied_ingredients.encounter_id as encounter_id, parent_concept.name as name FROM (
     SELECT count(*), encounter.encounter_id, regimen_ingredient.concept_id FROM encounter
     INNER JOIN orders ON orders.encounter_id = encounter.encounter_id
     INNER JOIN drug_order ON drug_order.order_id = orders.order_id
     INNER JOIN drug ON drug_order.drug_inventory_id = drug.drug_id
     INNER JOIN drug_ingredient as dispensed_ingredient ON drug.concept_id = dispensed_ingredient.concept_id
     INNER JOIN drug_ingredient as regimen_ingredient ON regimen_ingredient.ingredient_id = dispensed_ingredient.ingredient_id 
     INNER JOIN concept as regimen_concept ON regimen_ingredient.concept_id = regimen_concept.concept_id 
     WHERE encounter.encounter_type = 3 AND regimen_concept.class_id = 18 AND orders.voided = 0
     GROUP BY encounter.encounter_id, regimen_ingredient.concept_id, regimen_ingredient.ingredient_id) as satisfied_ingredients
    INNER JOIN concept_set AS parent_concept_set ON parent_concept_set.concept_id = satisfied_ingredients.concept_id
    INNER JOIN concept AS parent_concept ON parent_concept.concept_id = parent_concept_set.concept_set
    GROUP BY satisfied_ingredients.encounter_id, satisfied_ingredients.concept_id
    HAVING count(*) = (SELECT count(*) FROM drug_ingredient WHERE drug_ingredient.concept_id = satisfied_ingredients.concept_id)) as regimen ON regimen.encounter_id = encounter.encounter_id AND regimen.name = 'ARV First line regimen'
LEFT JOIN obs ON obs.encounter_id = encounter.encounter_id AND obs.concept_id = #{Concept.find_by_name('Date of ART initiation').id} 
GROUP BY patient_id, encounter_type
HAVING (encounter.encounter_type = #{EncounterType.find_by_name('Give drugs').id} AND MIN(DATE(encounter.encounter_datetime)) >= '#{@quarter_start.to_date}' AND MIN(DATE(encounter.encounter_datetime)) <= '#{@quarter_end.to_date}') 
    OR (MIN(DATE(obs.value_datetime)) >= '#{@quarter_start.to_date}' AND MIN(DATE(obs.value_datetime)) <= '#{@quarter_end.to_date}')
    ").map{|r|r["patient_id"]}
    i = 0
    limit = 80
    while (i < @patients_with_visits_or_initiation_in_cohort.length) do
      @patients = Patient.find(:all, :include => [:patient_names, :patient_identifiers, :encounters], :conditions => ["patient.patient_id IN (?)", @patients_with_visits_or_initiation_in_cohort[i..i+limit-1]])
      @patients.each{|this_patient|
        @cohort_values = this_patient.cohort_data(@quarter_start, @quarter_end, @cohort_values)
      }
      i += limit
    end
    #session[:cohort_patient_ids] = Report.cohort_patient_ids

		@cohort_values["side_effects_patients"] = @cohort_values["peripheral_neuropathy_patients"] + 
                                              @cohort_values["hepatitis_patients"] + 
		                                          @cohort_values["skin_rash_patients"] + 
                                              @cohort_values["lactic_acidosis_patients"] + 
														                  @cohort_values["lipodystropy_patients"] + 
                                              @cohort_values["anaemia_patients"] + 
                                              @cohort_values["other_side_effect_patients"]
   
    @survivals = nil
    render :layout => false and return if params[:id] == "Cumulative" 
    # survival analysis
    @start_date = subtract_months(@quarter_end, 2) #@quarter_start
    @start_date -= @start_date.day - 1
    @end_date = @quarter_end
    @survivals = Array.new
    date_ranges = Array.new
    survival_patients = Array.new
    

    # TODO: Remove magic number 3. Loop til the very first quarter
    (1..3).each{ |i|
      @start_date = subtract_months(@start_date, 12)
      @start_date -= @start_date.day - 1
      @end_date = subtract_months(@end_date, 12)
      date_ranges << {:start_date => @start_date, :end_date => @end_date}
      survival_patients[i-1] = Array.new
    }
    #@all_patients ||= Patient.find(:all)
    all_patients = Patient.find(:all)
    all_patients.collect{|patient| 
      start_date = patient.date_started_art
      date_ranges.each_with_index{|date_range,i|
        if start_date and start_date.between?(date_range[:start_date].to_time, date_range[:end_date].to_time)
          survival_patients[i] << patient
          survival_patients[i].length
          break
        end
      }
    }
    (1..3).each{ |i|
      @survivals << Report.survival_analysis_hash(survival_patients[i-1], @start_date, @end_date, @quarter_end, i)
    }

    # NOTE: There's another stand alone Survival Analysis page below
    # TODO: Remove magic number 3. Loop til the very first quarter
#    all_patients = Patient.find(:all)
#    (1..3).each{ |i|
#      @start_date = subtract_months(@start_date, 12)
#      @start_date -= @start_date.day - 1
#      @end_date = subtract_months(@end_date, 12)
#      @survivals << survival_analysis_hash(all_patients, @start_date, @end_date, @quarter_end, i)
#    }
    @survivals = @survivals.reverse
    render :layout => false
  end

	def calculate_duplicate_data
	 	@pmtct_pregnant_women_on_art += 1 if @pmtct_pregnant_women_on_art_found
		
		@pmtct_pregnant_women_on_art_found = false
	end

  # Stand alone Survival Analysis page. use this to run Survival Analysis only, without cohort
  # e.g. http://bart/reports/survival_analysis/Q4+2007 
  def survival_analysis
    redirect_to :action => 'select_cohort' and return if params[:id].nil?
    (@quarter_start, @quarter_end) = Report.cohort_date_range(params[:id])  

    @start_date = subtract_months(@quarter_end, 3) #@quarter_start
    @start_date -= @start_date.day - 1
    @end_date = @quarter_end
    @survivals = Array.new
    date_ranges = Array.new
    survival_patients = Array.new
    

    # TODO: Remove magic number 3. Loop til the very first quarter
    (1..3).each{ |i|
      @start_date = subtract_months(@start_date, 12)
      @start_date -= @start_date.day - 1
      @end_date = subtract_months(@end_date, 12)
      date_ranges << {:start_date => @start_date, :end_date => @end_date}
      survival_patients[i-1] = Array.new
    }
    all_patients = Patient.find(:all)
    all_patients.collect{|patient| 
      start_date = patient.date_started_art
      date_ranges.each_with_index{|date_range,i|
        if start_date and start_date.between?(date_range[:start_date].to_time, date_range[:end_date].to_time)
          survival_patients[i] << patient
          survival_patients[i].length
          break
        end
      }
    }
    (1..3).each{ |i|
      @survivals << Report.survival_analysis_hash(survival_patients[i-1], @start_date, @end_date, @quarter_end, i)
    }
    @survivals = @survivals.reverse

    @messages = Hash.new
  end

  def survival_analysis_hash(all_patients, start_date, end_date, outcome_end_date, count)
    registration_start_date = start_date
    registration_end_date = end_date
    outcome_end_date = outcome_end_date
    @outcomes = Hash.new

    @outcomes["Defaulted"] = 0
    @outcomes["On ART"] = 0
    @outcomes["Died"] = 0
    @outcomes["ART Stop"] = 0
    @outcomes["Transfer out"] = 0

    # TODO: Optimise. Loop through all patients once and assign each art patient
    # to an approproate Survival entry without breaking @outcomes['Total']
    @patients = all_patients.collect{|patient| 
      start_date = patient.date_started_art
      patient if start_date and 
                 start_date.between?(registration_start_date.to_time, registration_end_date.to_time)
    }.compact

    @outcomes["Title"] = "#{count*12} month survival: outcomes by end of #{outcome_end_date.strftime('%B %Y')}"
    @outcomes["Total"] = @patients.length
    @outcomes["Start Date"] = start_date
    @outcomes["End Date"] = end_date
    
    @patients.each{|patient|
      patient_outcome = patient.cohort_outcome_status(registration_start_date, outcome_end_date)

      if patient_outcome.downcase.include?("on art") and patient.defaulter?(outcome_end_date) 
        @outcomes["Defaulted"] += 1
      elsif patient_outcome.include?("Died")
        @outcomes["Died"] += 1
      elsif patient_outcome.include?("ART Stop")
        @outcomes["ART Stop"] += 1
      elsif patient_outcome.include?("Transfer")
        @outcomes["Transfer out"] += 1
      elsif patient_outcome.downcase.include?("on art")
        @outcomes["On ART"] += 1
      else
        if @outcomes.has_key?(patient_outcome) then
          @outcomes[patient_outcome] += 1
        else
          @outcomes[patient_outcome] = 1
        end
      end

    }
    return @outcomes
  end
 
  def reception
    @all_people_registered = Patient.find(:all, :conditions => "voided = 0")
    @total_people_registered_with_filing_numbers  = 0
    @all_people_registered.each{|person|
      @total_people_registered_with_filing_numbers += 1 unless person.filing_number.nil?
    }
    @people_registered_today = Patient.find(:all, :conditions => ["voided = 0 AND DATE(date_created) = ?", Date.today])
    @total_people_registered_with_filing_numbers_today = 0
    @people_registered_today.each{|person|
      @total_people_registered_with_filing_numbers_today += 1 unless person.filing_number.nil?
    }
  end
  
  def data
    @all_people_registered = Patient.find(:all, :conditions => "voided = 0")
    @total_people_registered_with_filing_numbers  = 0
    @all_people_registered.each{|person|
      @total_people_registered_with_filing_numbers += 1 unless person.filing_number.nil?
    }
    @people_registered_today = Patient.find(:all, :conditions => ["voided = 0 AND DATE(date_created) = ?", Date.today])
    @total_people_registered_with_filing_numbers_today = 0
    @people_registered_today.each{|person|
      @total_people_registered_with_filing_numbers_today += 1 unless person.filing_number.nil?
    }
  end
  
  def missed_appointments
     @patient_appointments = Patient.find(:all).collect{|pat|
      next if pat.date_started_art.nil?; 
      next if pat.outcome_status =~/Died|Transfer|Stop/; 
      next if pat.drug_orders.nil? or pat.drug_orders.empty?
      next if pat.next_appointment_date and pat.next_appointment_date.to_time > Date.today.to_time;
      pat
    }.compact
    render:layout => true;
  end

  def defaulters
    @defaulters = Patient.art_patients(:include_outcomes => [Concept.find_by_name("Defaulter")])
  end
  
  def select
    if params[:report]
      case  params[:report]
        when "Patient register"
           redirect_to :action => "virtual_art_register"
           return
        when "Cohort"
           redirect_to :action => "select_cohort"
           return
        when "Missed appointments"
           redirect_to :action => "missed_appointments"
           return
        when "Defaulters"
           redirect_to :action => "defaulters"
           return
        when "Drug quantities"
           redirect_to :action => "select_monthly_drug_quantities"
           return
      end
    end

   render:layout => "application";
  end

	def virtual_art_register
		# delete cache report if ?refresh appended to url
		#expire_page :action => "virtual_art_register" unless params[:refresh].nil? 

		@patients=Patient.virtual_register
		@i = @patients.length
		redirect_to :action =>"virtual_art_register" and return if @patients.nil?
		@quarter=(Time.now().month.to_f/3).ceil.to_s
		render(:layout => false)
  end
  
  def download_virtual_art_register
     @patients = Patient.virtual_register
     csv_string = FasterCSV.generate{|csv|
       csv<<["ARV #","Qrtr","Reg Date","Name","Sex","Age","Occupation","ART Start date","Start Reason","PTB","EPTB","KS","PMTCT","Outcome","Reg.","Ambulant","Work/School","Weight at Starting","Weight at last visit","Peripheral neuropathy","Hepatitis","Skin rash","Lactic acidosis"," Lipodistrophy","Anaemia","Other side effect","Remaining tablets"]
       counter = 0
       @patients.sort {|a,b| a[1].arv_registration_number[4..-1].to_i <=> b[1].arv_registration_number[4..-1].to_i }.each do |hash_key,visits | 
       counter += 1
       csv<<[visits.arv_registration_number,visits.quarter,visits.date_of_registration,visits.name,visits.sex, visits.age,visits.occupation, visits.date_of_art_initiation,visits.reason_for_starting_arv,visits.ptb, visits.eptb, visits.kaposissarcoma, visits.refered_by_pmtct,visits.outcome_status,visits.arv_regimen, visits.ambulant,  visits.at_work_or_school,visits.last_weight,visits.first_weight,visits.peripheral_neuropathy,visits.hepatitis,visits.skin_rash,visits.lactic_acidosis,visits.lipodystrophy,visits.anaemia,visits.other_side_effect,visits.tablets_remaining]
       end unless @patients.nil?
     
     }
     file_name ="#{Time.now}_virtual_patient_register.csv"
     send_data(csv_string,
      :type => 'text/csv; charset=utf-8; header=present',
      :filename => file_name)
  end
  
  def pill_counts
    @patients = Patient.find(:all)
  end

  def select_monthly_drug_quantities
    if params[:report_year] and params[:report_month]
			redirect_to "/reports/monthly_drug_quantities/#{params[:report_year]}_#{params[:report_month]}"
      return 
    end
    render :layout => "application"
  end

  def monthly_drug_quantities
    year_month = []
    if params[:id].nil?
      redirect_to(:action => action_name, 
                  :id => "#{Date.today.year}_#{Date.today.month}")
      return
    end 
    year_month = params[:id].split("_") || nil
    @year = year_month[0].to_i || Date.today.year
    @month = year_month[1].to_i || Date.today.month

    @month_names = {1 => "Jan", 2 => "Feb", 3 => "Mar", 4 => "Apr", 5 => "May",
                    6 => "Jun", 7 => "Jul", 8 => "Aug", 9 => "Sep", 10 => "Oct",
                    11 => "Nov", 12 => "Dec"}

    # create drug hash
    @drug_quantities = Hash.new
    Drug.find(:all).each{|drug|
      @drug_quantities[drug.name] = drug.month_quantity(@year, @month)
    }

    @drug_quantities = @drug_quantities.sort{|a,b| a[0] <=> b[0]}
    @messages = Array.new
  end

  def cohort_patients
  end

  def cohort_debugger
    #@patient_ids = Report.cohort_patient_ids[:all]
    cohort_patient_ids = params[:cohort_patient_ids] || session[:cohort_patient_ids] rescue nil
    @key = :all
    @field = ''

    if params[:cohort_patient_ids] #use all ids from params
      @key = params[:id].to_sym
      @field = params[:field]
      @patient_ids = cohort_patient_ids.split(',')
      @filter = params[:filter]
      return
    elsif params[:id] and params[:field] #extract from session
      @key = params[:id].to_sym
      @field = params[:field]
      @patient_ids = cohort_patient_ids[@key][@field] 
    elsif cohort_patient_ids
      @patient_ids = cohort_patient_ids[:all]
    else
      render :text => "Error: Could not get the list of patients to debug. <a href='javascript:history.back();'>Back</a>"
    end
  end

  def duplicate_identifiers
    error_text = "Missing a Patient Identifier Type ID<br/>"
    error_text += "e.g. <a href='/reports/duplicate_identifiers/18'>Duplicate ARV Numbers</a>"
    render :text => error_text and return if params[:id].nil?

    identifier_type = PatientIdentifierType.find(params[:id].to_i)
    @identifiers = PatientIdentifier.duplicates_by_type(identifier_type)
    @title = identifier_type.name
  end

end


