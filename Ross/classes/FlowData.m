classdef FlowData < handle
	% A data structure for managing flow cytometry data. Uses and references
	% several other classes and functions in the repository. 
	%
	%	Settable Properties
	%		binInputs		<struct>	Struct w/ bin channels as fields and edges as values
	%		binDataType		<char>		Binned dataType ('raw', 'mComp', 'mefl', etc)
	%		binGate			<char>		Gate name for cell population to bin
	%
	%	Visible Properties
	%		numSamples		<numeric>	The number of data samples
	%		numCells		<array>		The number of cells in each sample
	%		sampleData		<struct>	Sample fluorescence and gate data in standard struct
	%		sampleMap		<table>		Experimental information for samples
	%		dataTypes		<cell>		Cell array of data types 
	%									('raw', 'mComp', 'mefl', etc)
	%		gateNames		<cell>		Cell array of gate names (strings)
	%		gatePolygons	<struct>	Defined gates that can be applied to data
	%									Fields: gate names. Values: Gate polygons.
	%		channels		<cell>		Cell array of channel names
	%		controlData		<struct>	Similar to sampleData but for controls.
	%									The order of controls should be the same
	%									as their corresponding channels. 
	%		fitParams		<struct>	Struct containing matrix compensation fitting results.
	%		bins			<cell>		Cell array where each element corresponds
	%									with a data sample and contains an N-dim
	%									M-element/dim cell array with an array of
	%									cell IDs in each bin. 
	%										N = numel(binChannels)
	%										M = numBins
	%										cell IDs for binDataType/binGate
	%
	%	Public Methods
	%
	%		FlowData
	%		gate
	%		addControls
	%		convertToMEF
	%		compensate
	%		bin
	%		getValues
	%		getSampleIDs
	%		slice
	
	%#ok<*AGROW>
	
	properties (SetObservable)
		binInputs = struct();		% Struct w/ bin channels as fields and edges as values
		binDataType = '';			% Binned dataType ('raw', 'mComp', 'mefl', etc)
		binGate = '';				% Gate name for cell population to bin
	end
	
	
	properties (SetObservable, Hidden)
		test = '';
	end
	
	
	properties (SetAccess = private)
		numSamples = 0;				% The number of data samples
		numCells = [];				% The number of cells in each sample
		sampleData = struct();		% Sample fluorescence and gate data in standard struct
		sampleMap = table();		% Experimental information for samples
		
		dataTypes = {};				% Cell array of data types ('raw', 'mComp', 'mefl', etc)
		gateNames = {};				% Cell array of gate names (strings)
		gatePolygons = struct();	% Defined gates that can be applied to data. Fields: gate names. Values: Gate polygons.
		
		channels = {};				% Cell array of channel names
		controlData = struct();		% Similar to sampleData but for controls
		fitParams = struct();		% Struct containing matrix compensation fitting results
		
		bins = {};					% Cell array where each element corresponds with a data sample
	end
	
	
	properties (Access = private)
		sampleDataScatter = struct();	% Contains sampleData forward/side scatter values
	end
	
	
	properties (Access = private, Constant)
		SCATTER_CHANNELS = {'FSC_A', 'FSC_H', 'FSC_W', 'SSC_A', 'SSC_H', 'SSC_W'};
	end
	
	
	methods (Access = public)
		
		function self = FlowData(dataStruct, channels, sampleMap)
			% Initializes the FlowData object 
			% with a dataStruct generated by importing files with FlowAnalysis.importData(...)
			%
			%	self = FlowData(dataStruct, channels, sampleMap)
			%
			%	Inputs
			%		dataStruct		<struct> The data struct from which to 
			%						extract data. Can be any size. 
			%						** Should be sorted so that the position in
			%						the struct array coincides with the sample
			%						number in sampleMap
			%
			%		channels		<cell, char> The color channel(s) corresponding
			%						with the desired subset of data in dataStruct.
			%						**Must be a field of dataStruct
			%						**FSC/SSC are automatically taken
			%
			%		sampleMap		<char> The name of the .txt file containing 
			%						treatments information for each sample. 
			%						**See example file in source folder.
			%
			%	Outputs
			%		self			A handle to the object
			
			checkInputs()
			
			% Extract sample map
			self.sampleMap = readtable(sampleMap, 'delimiter', '\t');
			
			% Extract data from the given channels
			self.numSamples = numel(dataStruct);
			self.numCells = zeros(1, self.numSamples);
			for i = 1:self.numSamples
				self.numCells(i) = dataStruct(i).nObs;
				
				for ch = [channels, {'nObs'}]
					% Extract desired color channels
					self.sampleData(i).(ch{:}) = ...
						 dataStruct(i).(ch{:});
				end
				
				for ch = [self.SCATTER_CHANNELS, {'nObs'}]
					% Extract scatter channels
					self.sampleDataScatter(i).(ch{:}) = ...
						 dataStruct(i).(ch{:});
				end
			end
			self.dataTypes = fieldnames(dataStruct(1).(channels{1}));
			self.channels = channels;
			
			% Add listeners for settable public properties
			addlistener(self, 'test', 'PostSet', @self.handlePropEvents);
			addlistener(self, {'binInputs', 'binDataType', 'binGate'}, ...
				'PostSet', @self.handlePropEvents);
			
			fprintf(1, 'Finished constructing FlowData object\n')
			
			
			% -- Helper functions -- %
			
			
			function checkInputs()
				validateattributes(dataStruct, {'struct'}, {}, mfilename, 'dataStruct', 1)
				validateattributes(channels, {'cell', 'char'}, {}, mfilename, 'channels', 2)
				validateattributes(sampleMap, {'char'}, {}, mfilename, 'sampleMap', 3)

				% Convert channels to cell array if single char value is given
				if ischar(channels), channels = {channels}; end
				channels = reshape(channels, 1, []); % Ensure row vector

				% Check channels are present in dataStruct
				badChannels = setdiff(channels, fieldnames(dataStruct(1)));
				assert(isempty(badChannels), ...
					'Channel not in dataStruct: %s\n', badChannels{:});
				
				% Check sampleMap is a real file
				assert(logical(exist(sampleMap, 'file')), ...
					'File not found: %s\n', sampleMap)
			end
		end
		
		
		function gate(self)
			% Creates gates for the data using standard gating (see Gating.m)
			%
			%	self.gate()
			
			% First combine a subset of all the data to gate together
			sampleDataScatterCombined = struct();
			for ch = self.SCATTER_CHANNELS
				combData = [];
				for i = 1:self.numSamples
					combData = [combData; self.sampleDataScatter(i).(ch{:}).raw(1:self.numSamples:end)];
				end
				sampleDataScatterCombined.(ch{:}).raw = combData;
			end
			sampleDataScatterCombined.nObs = numel( ...
						sampleDataScatterCombined.(self.SCATTER_CHANNELS{1}).raw);

			% Gate combined scatter data
			[gateP1, gateP2, gateP3] = Gating.standardGating(sampleDataScatterCombined);
			self.gatePolygons.P1 = gateP1;
			self.gatePolygons.P2 = gateP2;
			self.gatePolygons.P3 = gateP3;
			self.addGates({'P1', 'P2', 'P3'});
			
			% Apply gate polygons to scatter data and record gate logicles
			for i = 1:self.numSamples
				gatedData = Gating.applyStandardGates(self.sampleDataScatter(i), ...
										gateP1, gateP2, gateP3);
				for g = {'P1', 'P2', 'P3'}
					self.sampleData(i).gates.(g{:}) = gatedData.gates.(g{:});
					self.sampleDataScatter(i).gates.(g{:}) = gatedData.gates.(g{:});
				end
			end
			
			fprintf(1, 'Finished standard gating\n')
		end
		
		
		function crossGates(self, mode, gates)
			% Crosses the given gates using the given crossing mode
			% A new gate is created with name in the following form: 
			%		'gate1_gate2_gate3_[...]_gateN'
			%
			%	self.crossGates(mode, gates)
			%
			%	Inputs
			%		mode		<char> {'or', 'and'} - determines how gates are crossed
			%		varargin	<cell> A cell list of gate names to cross. Must be >= 2 gates
			
			% Check inputs
			validatestring(mode, {'and', 'or'}, mfilename, 'mode', 1);
			validateattributes(gates, {'cell'}, {'vector'}, mfilename, 'gates', 2);
			
			badGates = setdiff(gates, self.gateNames);
			assert(isempty(badGates), 'Gate does not exist: %s\n', badGates{:});
			newGateName = [gates{1}, sprintf('_%s', gates{2:end})];
			
			% Do gate crossing
			switch mode
				case 'or'
					for i = 1:self.numSamples
						self.sampleData(i) = crossOR(self.sampleData(i), newGateName);
					end
					for i = 1:numel(self.controlData)
						self.controlData(i) = crossOR(self.controlData(i), newGateName);
					end
				case 'and'
					for i = 1:self.numSamples
						self.sampleData(i) = crossAND(self.sampleData(i), newGateName);
					end
					for i = 1:numel(self.controlData)
						self.controlData(i) = crossAND(self.controlData(i), newGateName);
					end
			end
			
			self.addGates(newGateName);
			fprintf(1, 'Finished crossing gates\n')
			
			
			% --- Helper functions --- %
			
			
			function data = crossOR(data, newGateName)
				% Crosses w/ OR logic
				
				crossedGates = false(size(data.gates.(gates{1})));
				for g = 1:numel(gates)
					crossedGates = (crossedGates | data.gates.(gates{g}));
				end
				data.gates.(newGateName) = crossedGates;
			end
			
			
			function data = crossAND(data, newGateName)
				% Crosses w/ AND logic 
				
				crossedGates = true(size(data.gates.(gates{1})));
				for g = 1:numel(gates)
					crossedGates = (crossedGates & data.gates.(gates{g}));
				end
				data.gates.(newGateName) = crossedGates;
			end
		end
		
		
		function addControls(self, wildTypeData, singleColorData)
			% Adds wild-type data and single color data (structs) to the dataset
			% so that we can do compensation 
			% 
			%	self.addControls(wildTypeData, singleColorData)
			%
			%	Inputs
			%		wildTypeData		<struct> Wild-type cell data
			%		
			%		singleColorData		<struct> Single color controls data
			%							** Order of colors should coincide with
			%							the order of FlowData.channels
			
			% Check inputs
			validateattributes(wildTypeData, {'struct'}, {}, mfilename, 'wildTypeData', 1)
			validateattributes(singleColorData, {'struct'}, {}, mfilename, 'singleColorData', 2)
			assert(numel(singleColorData) == numel(self.channels), ...
				'Number of single color controls does not equal number of color channels!');
			
			% Extract data
			for ch = [self.channels, {'nObs', 'gates'}]
				for i = 1:numel(singleColorData)
					self.controlData(i).(ch{:}) = singleColorData(i).(ch{:});
				end
				self.controlData(i + 1).(ch{:}) = wildTypeData.(ch{:});
			end
			
			fprintf(1, 'Finished adding controls\n')
		end
		
		
		function convertToMEF(self, beadsControls, beadsSamples, showPlots)
			% Calibrate the data to standardized bead-based MEF units.
			% The controls must already have been added (see addControls())
			%
			%	self.convertToMEF(beadsFilename)
			%
			%	Inputs
			%		beadsControls	<struct> A struct with the following fields:
			%			beadFilename	The .fcs file containing bead data
			%							corresponding with this experiment
			%			beadType		The name of the type of bead (eg 'RCP-30-5A')
			%			beadLot			The bead production lot (eg 'AH01')
			%		beadsSamples	<struct> A struct with the same fields as above,
			%						but for the samples rather than controls
			%		showPlots		<logical> Flag to show fitted plots
			
			assert(~isempty(self.controlData), ...
				'Control data not been set yet! Call addControls() before using this function\n')
			
			% Check inputs
			[filenameControls, typeControls, lotControls, ...
			 filenameSamples, typeSamples, lotSamples] = checkInputs();
			
			% Get MEF fits 
			fitsControls = Transforms.calibrateMEF(filenameControls, ...
						typeControls, lotControls, self.channels, showPlots);
			if isequaln(beadsControls, beadsSamples)
				% If the bead properties are the same, then skip the fitting for
				% samples' beads and just use the controls' beads. This is for 
				% the case where samples and controls are run the same day.
				fitsSamples = fitsControls;
			else
				fitsSamples = Transforms.calibrateMEF(filenameSamples, ...
							typeSamples, lotSamples, self.channels, showPlots);
			end
			
			% Apply calibration to controls
			self.controlData = Transforms.fcs2MEF(self.controlData, fitsControls, 'raw');
			
			% Apply calibration to data
			self.sampleData = Transforms.fcs2MEF(self.sampleData, fitsSamples, 'raw');
			
			self.addDataTypes('mef');
			self.addGates('nneg');
			self.crossGates('and', {'P3', 'nneg'});
			
			fprintf(1, 'Finished converting to MEF\n')
			
			
			
			
			function [filenameControls, typeControls, lotControls, ...
					  filenameSamples, typeSamples, lotSamples] = checkInputs()
				
				validateattributes(beadsControls, {'struct'}, {}, mfilename, 'beadsFilename', 1);
				validateattributes(beadsSamples, {'struct'}, {}, mfilename, 'beadsFilename', 2);
				
				validFields = {'filename', 'type', 'lot'};
				badFieldsControls = setdiff(fieldnames(beadsControls), validFields);
				badFieldsSamples  = setdiff(fieldnames(beadsSamples), validFields);
				assert(isempty(badFieldsControls), 'Field not valid: %s\n', badFieldsControls{:})
				assert(isempty(badFieldsSamples), 'Field not valid: %s\n', badFieldsSamples{:})
				
				filenameControls = beadsControls.filename;
				typeControls = beadsControls.type;
				lotControls = beadsControls.lot;
				
				filenameSamples = beadsSamples.filename;
				typeSamples = beadsSamples.type;
				lotSamples = beadsSamples.lot;
				
				assert(logical(exist(filenameControls, 'file')), ...
					'File does not exist: %s\n', filenameControls)
				assert(logical(exist(filenameSamples, 'file')), ...
					'File does not exist: %s\n', filenameSamples)
				
			end
		end
		
		
		function compensate(self, method, plotsOn)
			% Applies compensation to the data
			%
			%	self.compensate(method, plotsOn)
			%
			%	Inputs
			%		method			<char> Indicates which compensation routine
			%						to use. 
			%							'scComp'	piecewise linear
			%							'mComp'		matrix-based
			%
			%		plotsOn			(optional) <logical> Set to TRUE to show the 
			%						compensation function's generated plots. 
			
			% Check inputs
			validatestring(method, {'scComp', 'mComp'}, mfilename, 'method', 1);
			if exist('plotsOn', 'var')
				plotsOn = logical(plotsOn);
			end
			
			switch method
				case 'scComp'
					self.sampleData = FlowAnalysis.compensateBatchSC( ...
						self.controlData(end), self.controlData(1:(end-1)), self.channels, ...
						 self.sampleData, self.channels, 'mef', 'P3_nneg', plotsOn);
					self.addDataTypes('scComp');
				
				case 'mComp'
					[self.sampleData, wtData_fixed, scData_fixed, self.fitParams] = ...
						FlowAnalysis.compensateMatrixBatch( ...
							self.sampleData, self.channels, self.controlData(end), ...
							self.controlData(1:(end-1)), 'mef', 'P3_nneg', plotsOn);
					self.controlData = [scData_fixed, wtData_fixed];
					self.addDataTypes({'afs', 'mComp'});
			end
			
			fprintf(1, 'Finished compensation\n')
		end
		
		
		function bin(self, binInputs, binDataType, binGate)
			% Bins the data by the input channels into the given number of bins 
			%
			%	self.bin(binEdges, binChannels, binDataType, binGate)
			%
			%	Inputs
			%		inputs			<struct> A struct with channel names as keys and 
			%						bin edges as values. The channel names must match 
			%						a field in the data struct with the subfield 'raw'. 
			%						The struct tells the function which channels to bin 
			%						on and where to draw the bins in each dimension. 
			%		
			%		binDataType		<char> The cell dataType to use (eg 'mefl', 'mComp')
			%
			%		binGate			(optional) <char> The gated cell population 
			%						to use for binning (default: 'P3')
			
			[binChannels, binEdges] = checkInputs_bin(self);
			
			for i = 1:self.numSamples
				sliceParams = struct( ...
					'channels', {binChannels}, ...
					'dataType', binDataType, ...
					'gate', binGate);
				
				slicedData = self.slice(i, sliceParams);
				
				self.bins{i} = FlowAnalysis.simpleBin(Transforms.lin2logicle(slicedData), binEdges);
			end
			
			fprintf(1, 'Finished binning\n')
			
			
			% --- Helper Functions --- %
			
			
			function [binChannels, binEdges] = checkInputs_bin(self)
				% Validates that the given bin properties are ok, then sets the
				% object's properties themselves if all are ok.

				% Check properties
				validateattributes(binInputs, {'struct'}, {}, mfilename, 'inputs', 1);
				binChannels = reshape(fieldnames(binInputs), 1, []);
				validateattributes(binChannels, {'cell', 'char'}, {}, mfilename, 'binChannels');
				badChannels = setdiff(binChannels, self.channels);
				assert(isempty(badChannels), ...
						'Channel not allowed: %s\n', badChannels{:});
				
				binEdges = cell(1, numel(binChannels));
				for ch = 1:numel(binChannels)
					assert(numel(binInputs.(binChannels{ch})) > 1, ...
							'Must have more than one bin edge to define a bin!');
					binEdges{ch} = binInputs.(binChannels{ch});
				end
				
				validateattributes(binDataType, {'char'}, {}, mfilename, 'binDataType', 2);
				assert(any(strcmp(binDataType, self.dataTypes)), ...
						'Bin data type does not match any existing data types: %s\n', binDataType);

				validateattributes(binGate, {'char'}, {}, mfilename, 'binGate', 3);
				assert(any(strcmp(binGate, self.gateNames)), ...
						'Gate does not exist in data: %s\n', binGate);

				self.binInputs = binInputs;
				self.binDataType = binDataType;
				self.binGate = binGate;
			end
		end
			
		
		function values = getValues(self, parameters)
			% Returns unique values for each given experimental parameter.
			%
			%	values = self.getValues(paramters)
			%
			%	Inputs
			%		parameters	<char, cell> A cell array of strings with parameter
			%					names corresponding with paramters in sampleMap.
			%					Can be a string if just one parameter.
			%	
			%	Outputs
			%		values		<struct> a struct where each parameter is a field
			%					containing each unique parameter value as found
			%					in sampleMap. 
			
			% Check parameters
			validateattributes(parameters, {'char', 'cell'}, {}, mfilename, 'parameters', 1);
			if ischar(parameters), parameters = {parameters}; end % For simplification
			validParameters = self.sampleMap.Properties.VariableNames;
			parameters = reshape(parameters, 1, []); % Force row vector
			for param = parameters
				validatestring(param{:}, validParameters)
			end
			
			% Extract unique values for each parameter
			values = struct();
			for param = parameters
				values.(param{:}) = unique(self.sampleMap.(param{:}));
			end
		end
		
		
		function sampleIDs = getSampleIDs(self, treatments)
			% Returns an array of sample IDs corresponding with the given treatments in the order requested
			%
			%	sampleIDs = self.getSampleIDs(treatments)
			%
			%	Inputs
			%		treatments	<struct> A struct where the fields correspond with 
			%					table headers in sampleMap and the values are arrays 
			%					of treatment parameters to be matched in the table.
			%
			%	Outputs
			%		sampleIDs	<numeric> A matrix of sample IDs. Each dimension
			%					in the matrix corresponds with one field of the
			%					'treatments' input. The order of the dimensions
			%					corresponds with the order fields were added to
			%					the struct (since that is the order they pop out
			%					when using the fieldnames() function). 

			% Check treatment requests
			validateattributes(treatments, {'struct'}, {}, mfilename, 'treatments', 1);
			treatmentFields = reshape(fieldnames(treatments), 1, []);
			numTreatments = numel(treatmentFields);
			badFields = setdiff(treatmentFields, self.sampleMap.Properties.VariableNames);
			assert(isempty(badFields), ...
				'Field not in sampleMap: %s\n', badFields{:});

			% This is used to help rotate the sample IDs into the requested order
			numParams = zeros(1, numTreatments);
			
			% Iterate over fields and order the sample IDs based on matching
			% treatment parameters in the order treatments are requested.
			for i = 1:numTreatments
				
				f = treatmentFields{i};
				treatmentParams = reshape(treatments.(f), 1, []); % Turn into row vector so we can do parallel comparisons
				numParams(i) = numel(treatmentParams);
				matchingSamples = (self.sampleMap.(f) == treatmentParams); % Logical indexes
				
				if (i == 1)
					% On first treatment, extract IDs exactly
					IDs = matchingSamples;
				else
					% For subsequent treatments, we add a dimension to the index
					% array which we can use to rapidly and easily find the
					% requested samples in treatment order.
					
					% The previous IDs are first replicated into the next
					% highest dimension (N)
					N = ndims(IDs) + 1;
					repDims = ones(1, N);
					repDims(end) = numel(treatmentParams);
					IDs = repmat(IDs, repDims);
					
					% Next we take the current matchingSamples and permute them
					% so that their columns now extend into the new dimension
					matchingSamples = permute(matchingSamples, [1, N : -1 : 2]);
					
					% Now we have to replicate matchingSamples into all
					% dimensions between 1 and N
					sizeIDs = size(IDs); % Form: [numSamples, [prevParams], currParam]
					matchingSamples = repmat(matchingSamples, [1, sizeIDs(2:end-1), 1]);
					
					IDs = (IDs & matchingSamples);
				end
			end
			
			% Extract sample IDs as numbers
			[linearSampleIDs, ~] = find(IDs);
			if (numel(numParams) > 1)
				sampleIDs = reshape(linearSampleIDs, numParams);
			else
				sampleIDs = linearSampleIDs;
			end
		end
		
		
		function dataMatrix = slice(self, sampleID, sliceParams)
			% Slices the data, returning an N x M matrix of data from N cells in M channels. 
			%
			%	dataMatrix = self.slice(sampleID, sliceParams)
			%
			%	Inputs
			%		sampleID		<integer> The sample to slice as given by
			%						the numerical sample ID.
			%		sliceParams		<struct> Optional, struct with optional fields:
			%						'channels': <cell, char>, defaults to self.channels
			%						'dataType': <char>, defaults to 'raw'
			%						'gate':		<char>, defaults to no gate
			%
			%	Ouputs
			%		dataMatrix		<double> N x M matrix of data from the given
			%						sample where N is the number of cells in the
			%						returned data and M is the number of
			%						channels requested. 
			
			% Check and extract inputs
			[sliceChannels, sliceDataType, sliceGate] = checkInputs_slice(self);
			
			% Slice out data
			dataMatrix = zeros(sum(sliceGate), numel(sliceChannels));
			for ch = 1:numel(sliceChannels)
				dataMatrix(:, ch) = self.sampleData(sampleID).(sliceChannels{ch}).(sliceDataType)(sliceGate);
			end
			
			
			 % --- Helper Functions --- %
			
			
			function [sliceChannels, sliceDataType, sliceGate] = checkInputs_slice(self)
				% Validates slice properteis and that the sampleID is valid
				
				% Ensure sampleID is a valid integer
				validateattributes(sampleID, {'numeric'}, {'scalar', 'positive'}, ...
					mfilename, 'sampleID', 1);
				sampleID = round(sampleID); 
				assert(sampleID <= numel(self.sampleData), ...
					'sampleID is too large!')
				
				% Check and update slice parameters as needed
				if exist('sliceParams', 'var')
					validateattributes(sliceParams, {'struct'}, {}, mfilename, 'sliceParams', 2);
				else
					sliceParams = struct();
				end
				
				if any(strcmp('channels', fieldnames(sliceParams)))
					sliceChannels = sliceParams.channels;
					sliceChannels = reshape(sliceChannels, 1, []); % Force row vector
					badChannels = setdiff(sliceChannels, self.channels);
					assert(isempty(badChannels), ...
							'Channel not allowed: %s\n', badChannels{:});
				else
					sliceChannels = self.channels; % Default is all channels
				end
				
				if any(strcmp('dataType', fieldnames(sliceParams)))
					validatestring(sliceParams.dataType, self.dataTypes, mfilename, 'sliceParams.dataType');
					sliceDataType = sliceParams.dataType;
				else
					sliceDataType = 'raw'; % Default is raw data
				end
				
				if any(strcmp('gate', fieldnames(sliceParams)))
					validatestring(sliceParams.gate, self.gateNames, mfilename, 'sliceParams.gate');
					sliceGate = self.sampleData(sampleID).gates.(sliceParams.gate);
				else
					sliceGate = true(self.numCells(sampleID), 1); % Default is all cells
				end
			end
		end
			
	end
	
	
	methods (Access = private)
		
		function handlePropEvents(src, event)
			% Function for handling changes to observable properties
			
			self = event.AffectedObject;
			
			fprintf(1, 'Property changed: %s\n', src.Name);
			switch src.Name
				case {'binInputs', 'binDataType', 'binGate'}
					self.bin(self.binInputs, self.binDataType, self.binGate)
				
				case {'test'}
					fprintf(1, 'Test set to: %s\n', event.AffectedObject.test);
			end
		end
		
		
		function addDataTypes(self, dataTypes)
			% Adds the given dataTypes to the dataTypes property if they are new
			
			validateattributes(dataTypes, {'cell', 'char'}, {}, mfilename, 'dataTypes', 1);
			
			if ~iscell(dataTypes), dataTypes = {dataTypes}; end % For simplicity
			
			% Add dataTypes
			added = {};
			for dt = 1:numel(dataTypes)
				if ~any(strcmp(dataTypes{dt}, self.dataTypes))
					self.dataTypes = [self.dataTypes, dataTypes(dt)];
					added = [added, dataTypes(dt)];
				end
			end
			
			if ~isempty(added), fprintf(1, 'Added dataType: %s\n', added{:}); end
		end
		
		
		function addGates(self, gates)
			% Adds the given gates to the gateNames property if they are new
			
			validateattributes(gates, {'cell', 'char'}, {}, mfilename, 'gates', 1);
			
			if ~iscell(gates), gates = {gates}; end % For simplicity
			
			% Add dataTypes
			added = {};
			for g = 1:numel(gates)
				if ~any(strcmp(gates{g}, self.gateNames))
					self.gateNames = [self.gateNames, gates(g)];
					added = [added, gates(g)];
				end
			end
			
			if ~isempty(added), fprintf(1, 'Added gate: %s\n', added{:}); end
		end
		
	end
end