##########################################
#
# Module WorkflowMgr
#
##########################################
module WorkflowMgr

  ########################################## 
  #
  # Class WorkflowXMLDoc 
  #
  ##########################################
  class WorkflowXMLDoc

    require 'libxml'
    require 'workflowmgr/utilities'
    require 'workflowmgr/cycledef'
    require 'workflowmgr/workflowlog'
    require 'workflowmgr/cycledef'
    require 'workflowmgr/sgebatchsystem'
    require 'workflowmgr/task'


    ##########################################
    #
    # initialize
    #
    ##########################################
    def initialize(workflowdoc)

      # Get the text from the xml file and put it into a string
      xmlstring=IO.readlines(workflowdoc,nil)[0]

      # Parse the workflow xml string, set option to replace entities
      @workflowdoc=LibXML::XML::Document.string(xmlstring,:options => LibXML::XML::Parser::Options::NOENT)

      # Validate the workflow xml document before metatask expansion
      validate_with_metatasks(@workflowdoc)

      # Expand metatasks
      expand_metatasks

      # Validate the workflow xml document after metatask expansion
      # The second validation is needed in case metatask expansion introduced invalid XML
      validate_without_metatasks(@workflowdoc)

    end  # initialize


    ##########################################
    #
    # realtime?
    # 
    ##########################################
    def realtime?

      if @workflowdoc.root["realtime"].nil?
        return nil
      else
        return !(@workflowdoc.root["realtime"].downcase =~ /^t|true$/).nil?
      end

    end


    ##########################################
    #
    # cyclelifespan
    # 
    ##########################################
    def cyclelifespan

      if @workflowdoc.root["cyclelifespan"].nil?
        return nil
      else
        return WorkflowMgr.ddhhmmss_to_seconds(@workflowdoc.root["cyclelifespan"])
      end

    end


    ##########################################
    #
    # cyclethrottle
    # 
    ##########################################
    def cyclethrottle

      if @workflowdoc.root["cyclethrottle"].nil?
        return nil
      else
        return @workflowdoc.root["cyclethrottle"].to_i
      end

    end


    ##########################################
    #
    # taskthrottle
    # 
    ##########################################
    def taskthrottle

      if @workflowdoc.root["taskthrottle"].nil?
        return nil
      else
        return @workflowdoc.root["taskthrottle"].to_i
      end

    end


    ##########################################
    #
    # corethrottle
    # 
    ##########################################
    def corethrottle

      if @workflowdoc.root["corethrottle"].nil?
        return nil
      else
        return @workflowdoc.root["corethrottle"].to_i
      end

    end


    ##########################################
    #
    # scheduler
    # 
    ##########################################
    def scheduler

      if @workflowdoc.root["scheduler"].nil?
        return nil
      else
        return WorkflowMgr::const_get("#{@workflowdoc.root["scheduler"].upcase}BatchSystem").new
      end

    end


    ##########################################
    #
    # log
    # 
    ##########################################
    def log
 
      lognode=@workflowdoc.find('/workflow/log').first
      path=get_compound_time_string(lognode)
      verbosity=lognode.attributes['verbosity']
      verbosity=verbosity.to_i unless verbosity.nil?

      return WorkflowLog.new(path,verbosity)

    end


    ##########################################
    #
    # cycledefs
    # 
    ##########################################
    def cycledefs
 
      cycles=[]
      cyclenodes=@workflowdoc.find('/workflow/cycledef')
      cyclenodes.each { |cyclenode|
        cyclefields=cyclenode.content
        nfields=cyclefields.split.size
        group=cyclenode.attributes['group']
        if nfields==3
          cycles << CycleInterval.new(cyclefields,group)
        elsif nfields==6
          cycles << CycleCron.new(cyclefields,group)
        else
	  raise "ERROR: Unsupported <cycle> type!"
        end
      }

      return cycles

    end


    ##########################################
    #
    # tasks
    # 
    ##########################################
    def tasks

      tasks=[]
      tasknodes=@workflowdoc.find('/workflow/task')
      tasknodes.each do |tasknode|

        taskattrs={}
        taskenvars={}
        taskdep=nil

        # Get task attributes insde the <task> tag
        tasknode.attributes.each do |attr|
          attrkey=attr.name.to_sym
          case attrkey
            when :maxtries              # Attributes with integer values go here
              attrval=attr.value.to_i
            else                        # Attributes with string values
              attrval=attr.value
          end
          taskattrs[attrkey]=attrval
        end

        # Get task attributes, envars, and dependencies declared as elements inside <task> element
        tasknode.each_element do |e|          
          case e.name
            when /^envar$/
              taskenvars[get_compound_time_string(e.find('name').first)] = get_compound_time_string(e.find('value').first)
            when /^dependency$/
              e.each_element do |element| 
                raise "ERROR: <dependency> tag contains too many elements" unless taskdep.nil?
                taskdep=Dependency.new(get_dependency_node(element))
              end
            else
              attrkey=e.name.to_sym
              case attrkey
                when :cores                      # <task> elements with integer values go here
                  attrval=e.content.to_i
                else                             # <task> elements with compoundtimestring values
                  attrval=get_compound_time_string(e)
              end
              taskattrs[attrkey]=attrval
          end
        end

        tasks << Task.new(taskattrs,taskenvars,taskdep)

      end

      return tasks

    end


    ##########################################
    #
    # taskdep_cycle_offsets
    # 
    ##########################################
    def taskdep_cycle_offsets

      offsets=[]
      taskdepnodes=@workflowdoc.find('//taskdep')
      taskdepnodes.each do |taskdepnode|
        offsets << WorkflowMgr.ddhhmmss_to_seconds(taskdepnode["cycle_offset"]) unless taskdepnode["cycle_offset"].nil?
      end
      return offsets.uniq  

    end


    ##########################################
    #
    # method_missing
    # 
    ##########################################
    def method_missing(name,*args)

      dockey=name.to_sym
      if @workflow.has_key?(dockey)
        return @workflow[dockey]
      else
	super
      end

    end


  private


     ##########################################
     #
     # get_compound_time_string
     # 
     ##########################################
     def get_compound_time_string(element)
 
       strarray=element.collect do |e|
         if e.node_type==LibXML::XML::Node::TEXT_NODE
           CycleString.new(e.content,0)
         else
           offset_sec=WorkflowMgr.ddhhmmss_to_seconds(e.attributes["offset"])
           case e.name
             when "cyclestr"
               formatstr=e.content.gsub(/@(\^?[^@\s])/,'%\1').gsub(/@@/,'@')
               CycleString.new(formatstr,offset_sec)
             else
               raise "Invalid tag <#{e.name}> inside #{element}: #{e.node_type_name}"
           end
         end
       end
 
       return CompoundTimeString.new(strarray)
 
     end


     ##########################################
     #
     # get_dependency_node
     # 
     ##########################################
     def get_dependency_node(element)
 
       # Build a dependency tree
       children=[]
       element.each_element { |e| children << e }
       case element.name
         when "not"
           return Dependency_NOT_Operator.new(children.collect { |child| get_dependency_node(child) })
         when "and"
           return Dependency_AND_Operator.new(children.collect { |child| get_dependency_node(child) })
         when "or"
           return Dependency_OR_Operator.new(children.collect { |child|  get_dependency_node(child) })
         when "nand"
           return Dependency_NAND_Operator.new(children.collect { |child|  get_dependency_node(child) })
         when "nor"
           return Dependency_NOR_Operator.new(children.collect { |child|  get_dependency_node(child) })
         when "xor"
           return Dependency_XOR_Operator.new(children.collect { |child|  get_dependency_node(child) })
         when "some"
           return Dependency_SOME_Operator.new(children.collect { |child|  get_dependency_node(child) }, element["threshold"])
         when "taskdep"
           return get_taskdep(element)
         when "datadep"
           return get_datadep(element)
         when "timedep"
           return get_timedep(element)
       end

     end


     #####################################################
     #
     # get_taskdep
     #
     #####################################################
     def get_taskdep(element)
 
       # Get the mandatory task attribute
       task=element.attributes["task"]
 
       # Get the status attribute
       status=element.attributes["status"] || "SUCCEEDED"
 
       # Get the cycle offset, if there is one
       cycle_offset=WorkflowMgr.ddhhmmss_to_seconds(element.attributes["cycle_offset"]) || 0
 
       return TaskDependency.new(task,status,cycle_offset)

     end


     ##########################################
     # 
     # get_datadep
     # 
     ##########################################
     def get_datadep(element)
 
       # Get the age attribute
       age_sec=WorkflowMgr.ddhhmmss_to_seconds(element.attributes["age"]) || 0

       return DataDependency.new(get_compound_time_string(element),age_sec)
 
     end

 

     #####################################################
     #
     # get_timedep
     #
     #####################################################
     def get_timedep(element)
 
       # Get the time cycle string
       return TimeDependency.new(get_compound_time_string(element))
 
     end


    ##########################################
    #
    # to_h
    # 
    ##########################################
    def to_h(doc)

      # Initialize the workflow hash to contain the <workflow> attributes
      workflow=get_node_attributes(doc.root)

      # Build hashes for the <workflow> child elements
      doc.root.each_element do |child|
        key=child.name.to_sym
	case key
          when :log
            value=log_to_h(child)
          when :cycledef
            value=cycledef_to_h(child)
          when :task
            value=task_to_h(child)
        end
        if workflow.has_key?(key)
          workflow[key]=([workflow[key]] + [value]).flatten
        else
	  workflow[key]=value
        end

      end

      return workflow

    end


    ##########################################
    #
    # get_node_attributes
    # 
    ##########################################
    def get_node_attributes(node)

      # Initialize empty hash
      nodehash={}

      # Loop over node's attributes and set hash key/value pairs
      node.each_attr { |attr| nodehash[attr.name.to_sym]=attr.value }

      return nodehash

    end


    ##########################################
    #
    # log_to_h
    # 
    ##########################################
    def log_to_h(node)

      # Get the log attributes
      log=get_node_attributes(node)
      
      # Get the log path
      log[:path]=compound_time_string_to_h(node)

      return log

    end


    ##########################################
    #
    # cycledef_to_h
    # 
    ##########################################
    def cycledef_to_h(node)

      # Get the cycle attributes
      cycledef=get_node_attributes(node)
      
      # Get the cycle field string
      cycledef[:cycledef]=node.content.strip

      return cycledef

    end


    ##########################################
    #
    # task_to_h
    # 
    ##########################################
    def task_to_h(node)

      # Get the task attributes
      task=get_node_attributes(node)
      
      # Get the task elements
      node.each_element do |child|
        key=child.name.to_sym
        case key
          when :envar
            value=envar_to_h(child)
          when :dependency
            value=dependency_to_h(child).first
          when :cores,:maxtries                    # List integer-only attributes here
	    value=child.content.to_i
          when :id                                 # List string attributes that can't be compound time strings	here
            value=child.content.strip              
          else                                     # Everything else is a compound time string
            value=compound_time_string_to_h(child)
        end

        if task.has_key?(key)
          task[key]=([task[key]] + [value]).flatten
        else
          task[key]=value
        end

      end

      return task

    end


    ##########################################
    #
    # envar_to_h
    # 
    ##########################################
    def envar_to_h(node)

      # Get the envar attributes
      envar=get_node_attributes(node)

      # Get the envar elements
      node.each_element do |child|
        envar[child.name.to_sym]=compound_time_string_to_h(child)
      end

      return envar

    end


    ##########################################
    #
    # dependency_to_h
    # 
    ##########################################
    def dependency_to_h(node)

      dependency=[]
      node.each_element do |child|
        key=child.name.to_sym
        case key
          when :datadep
            value=datadep_to_h(child)
          when :timedep
            value=timedep_to_h(child)
          when :taskdep
            value=taskdep_to_h(child)
          else
            value=get_node_attributes(child)
            value[key]=dependency_to_h(child)
        end
        dependency << value
      end

      return dependency

    end


    #####################################################
    #
    # datadep_to_h
    #
    #####################################################
    def datadep_to_h(node)

      # Get the datadeo attributes
      datadep=get_node_attributes(node)

      datadep[node.name.to_sym]=compound_time_string_to_h(node)

      return datadep

    end


    #####################################################
    #
    # taskdep_to_h
    #
    #####################################################
    def taskdep_to_h(node)

      taskdep=get_node_attributes(node)
      taskdep[node.name.to_sym]=taskdep[:task]
      taskdep.delete(:task)

      return taskdep

    end


    #####################################################
    #
    # timedep_to_h
    #
    #####################################################
    def timedep_to_h(node)

      timedep=get_node_attributes(node)

      # Get the time cycle string
      timedep[node.name.to_sym]=compound_time_string_to_h(node)

      return timedep

    end


    ##########################################
    #
    # compound_time_string_to_h
    # 
    ##########################################
    def compound_time_string_to_h(node)

      # Build an array of strings/hashes
      compound_time_string=node.collect do |child|       
        next if child.content.strip.empty?
        if child.name.to_sym==:text
          child.content.strip
        else          
          { child.name.to_sym=>child.content.strip.gsub(/@(\^?[^@\s])/,'%\1').gsub(/@@/,'@') }.merge(get_node_attributes(child))
        end
      end
      
    end


    ##########################################
    #
    # validate_with_metatasks
    # 
    ##########################################
    def validate_with_metatasks(doc)

      # Parse the Relax NG schema XML document
      relaxng_document = LibXML::XML::Document.file("#{File.dirname(__FILE__)}/schema_with_metatasks.rng")

      # Prepare the Relax NG schemas for validation
      relaxng_schema = LibXML::XML::RelaxNG.document(relaxng_document)

      # Validate the workflow XML file against the general Relax NG Schema that validates metatask tags
      doc.validate_relaxng(relaxng_schema)

    end


    ##########################################
    #
    # validate_without_metatasks
    #
    ##########################################
    def validate_without_metatasks(doc)

      # Parse the Relax NG schema XML document
      relaxng_document = LibXML::XML::Document.file("#{File.dirname(__FILE__)}/schema_without_metatasks.rng")

      # Prepare the Relax NG schemas for validation
      relaxng_schema = LibXML::XML::RelaxNG.document(relaxng_document)

      # Validate the workflow XML file against the general Relax NG Schema that validates metatask tags
      doc.validate_relaxng(relaxng_schema)

    end


    ##########################################
    #
    # expand_metatasks
    #
    ##########################################
    def expand_metatasks

    end


  end  # Class WorkflowXMLDoc

end  # Module WorkflowMgr
