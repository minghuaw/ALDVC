% =========================================================
% Augmented Lagrangian Digital Volume Correlation (ALDVC)
% =========================================================
% 
% Author: Jin Yang, Asst.Prof. @UT-Austin; Postdoc @UW-Madison; PhD '19 @Caltech;
% Contact: aldicdvc@gmail.com; jin.yang@austin.utexas.edu
% Date: 2017-2018.02, 2020.06, 2022.09
% =========================================================

%% Section 0: To prepare image stacks
% ====== Prepare volumetric image data files ======
% Please go to subfolder code: './DVC_images/GenerateVolMatfile.m' to
% transform your volumetric image stacks to a Matlab matfile for ALDVC code.

%% Section 1: To set up MATLAB environment
% ====== Clear MATLAB environment & mex set up tricubic interpolation ======
close all; clear all; clc; clearvars -global
fprintf('------------ Section 1 Start ------------ \n')
setenv('MW_MINGW64_LOC','C:\TDM-GCC-64'); %Modify this line if you install "TDM-GCC-64" on a different path
mex -O ba_interp3.cpp; warning('off'); 
% dbstop if error; %You can uncomment this line to jump to the code where there is an error
addpath('./func','./src','./plotFiles','./DVC_images','./plotFiles/export_fig-d966721','./func/regularizeNd');
fprintf('------------ Section 1 Done ------------ \n \n')


%% Section 2: To load images and define DVC parameters
fprintf('------------ Section 2 Start ------------ \n')

% ====== Pre-load images ======
fileName = 'vol_Sample14*.mat';  fileFolder = './DVC_images/'; %Change "filename" and "fileFolder" by yourself

try if isempty(fileFolder)~=1 %Check whether "fileFolder" exists
        cd(fileFolder); %Open "fileFolder" if it is a valid path
end; catch; end %Skip this step if "fileFolder" is not a valid path

% ====== Load images ======
[fileNameAll,Img,DVCpara] = ReadImageLarge3(fileName,1); %Load first (reference) vol matfile
%%%%%%% Previous version: [file_name,Img,DVCpara] = ReadImage3(filename); 
%%%%%%% Load all the volumetric image matfiles at one time, 
%%%%%%% which will require a large RAM space: 

try if isempty(fileFolder)~=1 %Check whether "fileFolder" exists
        cd('../'); %Return to previous parent path if "cd(fileFolder);" was executed before
end; catch; end %Skip this step if "fileFolder" is not a valid path 

% ====== Define DVC parameters ======
DVCpara.trackingMode = 'cumulative';  %Tracking mode: choose from {'cumulative':, 'incremental'}
DVCpara.interpMethod = 'cubic';       %Grayscale interpolation scheme: choose from {'linear','cubic'(default),'spline'}
DVCpara.displayIterOrNot = 0;         %Display Section 4 local DVC IC-GN iteration convergence {0:N; 1:Y}
DVCpara.Subpb1ICGNMaxIterNum = 100;   %Maximum IC-GN iterations in local DVC and ADMM Subpb1 (see our original paper for more info about ADMM)
DVCpara.ICGNtol = 1e-2;               %IC-GN stopping threshold in local DVC and ADMM Subpb1, unit: [voxel]
DVCpara.ADMMtol = 1e-2;               %ADMM stopping threshold, unit: [voxel]

% ====== Uncomment lines below to manually define VOI (volume of interest) ======
% E.g.: gridRange.gridxRange = [352,696]; %unit: [voxel]
%       gridRange.gridyRange = [352,696]; %unit: [voxel]
%       gridRange.gridzRange = [1, 200];  %unit: [voxel]

% ====== Normalize images ======
[ImgNormalized,DVCpara.gridRange] = funNormalizeImg3(Img,DVCpara.gridRange,'normalize'); 
clear Img; %Clear original variable "Img" to release RAM

% ====== Initialize variable storage ======
ImgSeqLength = length(fileNameAll);           %Define variable "ImgSeqLength" as total frame #
ResultDisp = cell(ImgSeqLength-1,1);            %To store solved displacements [U]
ResultDefGrad = cell(ImgSeqLength-1,1);         %To store solved deformation gradients [F]
ResultStrain = cell(ImgSeqLength-1,1);          %To store solved strain after Section 8
ResultMuBeta = cell(ImgSeqLength-1,1);          %To store parameters mu and beta used in ADMM Subpb2
ResultConvItPerEle = cell(ImgSeqLength-1,1);    %To store local and Subpb1 ICGN iteration #
ResultSizeOfFFTSearch = cell(ImgSeqLength-1,1); %To store the size of the initial guess search area

if strcmp(DVCpara.trackingMode,'cumulative')==1 %%%%%% (i) Cumulative tracking mode %%%%%%
    ResultCoordinatesFEM = [];                  %To store DVC-FE-mesh nodal points coordinates
    ResultElementsFEM = [];                     %To store DVC-FE-mesh elements (node connectivities)
elseif strcmp(DVCpara.trackingMode,'incremental')==1  %%%%%% (ii) Incremental tracking mode %%%%%%    
    ResultFEMeshEachFrame = cell(ImgSeqLength-1,1); %To store FE-mesh coordinates and elements
else %%%%%% (iii) Unknown tracking mode
    disp('Unknown tracking mode: please check "DVCpara.trackingMode!"');
end
fprintf('------------ Section 2 Done ------------ \n \n')
 

%% %%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
% Sections 3-6: To track each frame in an image sequence
% %%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
for ImgSeqNum = 2 : length(fileNameAll) %ImgSeqNum: index of frame in the image sequence
     
    disp(['Current image frame #/total: ', num2str(ImgSeqNum),'/',num2str(length(fileNameAll))]);
    
    %% Load image frames: 
    % Cumulative mode: Frame #1 vs. Frame #ImgSeqNum;
    % Incremental mode: Frame #(ImgSeqNum-1) vs. Frame #ImgSeqNum
    % -----------------------------
    try if isempty(fileFolder)~=1 %Check whether "fileFolder" exists
        cd(fileFolder); %Open "fileFolder" if it is a valid path
    end; catch; end %Skip this step if "fileFolder" is not a valid path
    % -----------------------------
    if strcmp(DVCpara.trackingMode,'cumulative')==1 %%%%%% (i) Cumulative tracking mode %%%%%%

        Img{1} = ImgNormalized{1}; %The first frame is reference, undeformed image stack

        load(fileNameAll{ImgSeqNum}); Img_temp{1} = vol{1}; %Load current frame
        [ImgNormalized_temp,~] = funNormalizeImg3(Img_temp,DVCpara.gridRange,'normalize'); %Normalize image
        Img{2} = ImgNormalized_temp{1}; clear Img_temp ImgNormalized_temp;

    elseif strcmp(DVCpara.trackingMode,'incremental')==1  %%%%%% (ii) Incremental tracking mode %%%%%%

        load(fileNameAll{ImgSeqNum-1}); Img_temp{1} = vol{1}; %Load previous frame
        [ImgNormalized_temp,~] = funNormalizeImg3(Img_temp,DVCpara.gridRange,'normalize'); %Normalize image
        Img{1} = ImgNormalized_temp{1}; clear Img_temp ImgNormalized_temp;

        load(fileNameAll{ImgSeqNum}); Img_temp{1} = vol{1}; %Load current frame
        [ImgNormalized_temp,~] = funNormalizeImg3(Img_temp,DVCpara.gridRange,'normalize'); %Normalize image
        Img{2} = ImgNormalized_temp{1}; clear Img_temp ImgNormalized_temp;

    else %%%%%% (iii) Unknown tracking mode
        disp('Unknown tracking mode: please check "DVCpara.trackingMode!"');
    end
    % -----------------------------

    try if isempty(fileFolder)~=1 %Check whether "fileFolder" exists
        cd('../'); %Return to previous parent path if "cd(fileFolder);" was executed before
    end; catch; end %Skip this step if "fileFolder" is not a valid path 
 

    %% Section 3: Find an initial guess of the unknown displacement field
    fprintf('\n'); fprintf('------------ Section 3 Start ------------ \n')
    %%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
    % This section is to calculate an initial guess of the unknown
    % deformation field of current frame.  
    %%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
    if ImgSeqNum==2 || DVCpara.newFFTSearch==1

        % ====== Integer Search ======
        tic; [xyz0,uvw0,cc,sizeOfFFTSearchRegion] = IntegerSearch3Multigrid(Img,DVCpara); 
        DVCpara.sizeOfFFTSearchRegion = sizeOfFFTSearchRegion; toc

        % ======== Find some bad inital guess points ========
        cc.ccThreshold = 1.25; %Cross-correlation coefficient threshold = (mean - ccThreshold*stdev for q-factor distribution) 
        DVCpara.qDICOrNot = 0; %Whether to apply the qDIC strategy to remove local bad points after cross-correlation 
        DVCpara.medianFilterThreshold = 0; %Median filter threshold
        [uvw,cc] = RemoveOutliers3(uvw0,cc,DVCpara.qDICOrNot,DVCpara.medianFilterThreshold); %Last term is the threshold value

        % ====== DVC-FE-mesh set up ======
        [DVCmesh] = MeshSetUp3(xyz0,DVCpara); %Generate 3D DVC-mesh 

        % ====== Assign initial values ======
        U0 = Init3(uvw,DVCmesh.xyz0); %Initialize the deformation displacement: [..., U0_pti_x, U0_pti_y, U0_pyi_z, ...]
        Plotdisp_show3(U0,DVCmesh.coordinatesFEM,DVCmesh.elementsFEM); %Plot displacement fields
    
        % ====== Save DVC-FE-mesh ======
        %%%%%% (i) Cumulative tracking mode %%%%%%
        if strcmp(DVCpara.trackingMode,'cumulative')==1 
            ResultCoordinatesFEM = DVCmesh.coordinatesFEM; %To store DVC-FE-mesh nodal points coordinates
            ResultElementsFEM = DVCmesh.elementsFEM; %To store DVC-FE-mesh elements (node connectivities)
            if ImgSeqNum==2 %To store DVC-FE-mesh
                ResultFEMeshEachFrame = struct( ...
                'coordinatesFEM',DVCmesh.coordinatesFEM,'elementsFEM',DVCmesh.elementsFEM, ...
                'xyz0',xyz0,'winsize',DVCpara.winsize,'winstepsize',DVCpara.winstepsize, ...
                'gridxyROIRange',DVCpara.gridRange,'sizeOfFFTSearchRegion',sizeOfFFTSearchRegion);
            end
        %%%%%% (ii) Incremental tracking mode %%%%%%
        elseif strcmp(DVCpara.trackingMode,'incremental')==1  
            ResultFEMeshEachFrame{ImgSeqNum-1} = struct( ...
                'coordinatesFEM',DVCmesh.coordinatesFEM,'elementsFEM',DVCmesh.elementsFEM, ...
                'xyz0',xyz0,'winsize',DVCpara.winsize,'winstepsize',DVCpara.winstepsize, ...
                'gridxyROIRange',DVCpara.gridRange,'sizeOfFFTSearchRegion',sizeOfFFTSearchRegion);
        else %%%%%% (iii) Unknown tracking mode
            disp('Unknown tracking mode: please check "DVCpara.trackingMode!"');
        end
          
    else %Using previous frame's results as an initial guess of next frame's displacement fields
        U0 = ResultDisp{ImgSeqNum-2}.U;
    end

    % ====== Spline interpolation images ======
    % Df = funImgGradient3(Img{1},'stencil7'); %Pre-compute image grayscale value gradients
    Df = struct(); Df.imgSize = size(Img{1}); %Store volumetric image stack size

    % ====== Compute image difference: f(X)-g(x+u) ======
    % PlotImgDiff(x0,y0,u,v,fNormalized,gNormalized); % Img grayscale value residual

    fprintf('------------ Section 3 Done ------------ \n \n')
 
     
    %% Section 4
    fprintf('------------ Section 4 Start ------------ \n')
    % %%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
    % This section is to solve the first local step in ALDVC: Subproblem 1.
    % It is the same with the conventional Local Subset DVC method.
    % %%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
     
    ALVarMu = 0; ALVarBeta = 0; %Parameters ALVarMu and ALVarBeta are set as 0 first
    ALADMMIterStep=1; ALSubpb1TimeCost=zeros(6,1); ALSubpb2TimeCost=zeros(6,1); %To store computation time
    convIterPerEle=zeros(size(DVCmesh.coordinatesFEM,1),6); %To store ICGN iteration steps

    disp(['***** Start step',num2str(ALADMMIterStep),' Subproblem1 *****']);
    
    %%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
    % DVCpara.interpmethod = 'cubic';       %Choose from {'linear','cubic','spline','default'}
    % DVCpara.displayIterOrNot = 0;         %Dispay ICGN iteration steps or not: {0-No; 1-Yes}
    % DVCpara.Subpb1ICGNMaxIterNum = 100;   %Maximum ICGN iteration steps 
    % ------ Start Local DIC IC-GN iteration ------
    [USubpb1,FSubpb1,HtempPar,ALSubpb1TimeCosttemp,convIterPerEletemp] = LocalICGN3( ...
        U0,DVCmesh.coordinatesFEM,Df,Img{1},Img{2},DVCpara,'GaussNewton',DVCpara.ICGNtol);
    ALSubpb1TimeCost(ALADMMIterStep) = ALSubpb1TimeCosttemp; 
    convIterPerEle(:,ALADMMIterStep) = convIterPerEletemp; 
   
    %%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
    % ------ Manually remove bad points after Local Subset DVC ------
    disp('--- Start to manually remove bad local points ---')
    MNL = size(DVCmesh.xyz0.x); uvw.u = reshape(USubpb1(1:3:end),MNL); 
    uvw.v = reshape(USubpb1(2:3:end),MNL); uvw.w = reshape(USubpb1(3:3:end),MNL); 

    [uvw,cc,RemoveOutliersList] = RemoveOutliers3(uvw,[],DVCpara.qDICOrNot,DVCpara.medianFilterThreshold);
    USubpb1 = [uvw.u(:),uvw.v(:),uvw.w(:)]'; USubpb1 = USubpb1(:); FSubpb1 = FSubpb1(:);
    for tempi = 0:8
        FSubpb1(9*RemoveOutliersList-tempi) = nan;
        FSubpb1(9-tempi:9:end) = reshape((inpaint_nans3(reshape(FSubpb1(9-tempi:9:end),MNL),1)),size(DVCmesh.coordinatesFEM,1),1);
    end
    disp('--- Remove bad points: Done. ---')
    
    %%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
    % ------ Plot & save variables ------
    close all; Plotdisp_show3(USubpb1,DVCmesh.coordinatesFEM,DVCmesh.elementsFEM);  %Plot displacement fields
    Plotstrain_show3(FSubpb1,DVCmesh.coordinatesFEM,DVCmesh.elementsFEM);           %Plot small strain fields
    save(['Subpb1_step',num2str(ALADMMIterStep)],'USubpb1','FSubpb1');              %Save solved results: U & F
    ULocalICGN = USubpb1; FLocalICGN = FSubpb1; %Also save these results for future comparison since they are from the conventional DVC method
    fprintf('------------ Section 4 Done ------------ \n \n')
     
    
    %% Section 5
    fprintf('------------ Section 5 Start ------------ \n')
    % %%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
    % This section is to solve the global step in ALDVC: Subproblem 2
    % %%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
    
    %%%%%%% These steps are optional %%%%%%%
    % ------ Apply the Gaussian filter to denoise deformation gradient tensor "F" ------
    DVCpara.DispFilterSize=0; DVCpara.DispFilterStd=0; DVCpara.StrainFilterSize=0; DVCpara.StrainFilterStd=0;  
    for tempi=1:3, FSubpb1 = funSmoothStrain3(FSubpb1,DVCmesh,DVCpara); end
    % ------ Apply the Gaussian filter to denoise solved displacement "U" ------
    % prompt = 'Do you want to smooth displacement? (0-yes; 1-no)';
    % DoYouWantToSmoothOnceMore = input(prompt); DispFilterSize=0; DispFilterStd=0;
    % if DoYouWantToSmoothOnceMore == 0,USubpb1 = funSmoothDisp(USubpb1,coordinatesFEM,elementsFEM,winstepsize,DispFilterSize,DispFilterStd);end
    % for tempi = 1:SmoothTimesDisp, USubpb1 = funSmoothDisp3(USubpb1,DVCmesh,DVCpara); end
    % Plotdisp_show3(USubpb1,coordinatesFEM,elementsFEM);
    
    %%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
    % ====== Define penalty parameter ======
    ALVarMu = 1e-3; udual = 0*FSubpb1; vdual = 0*USubpb1; %Initialize variable "ALVarMu", and dual variables
    ALVarBetaList = [sqrt(1e-5),1e-2,sqrt(1e-3),1e-1,sqrt(1e-1)]*mean(DVCpara.winstepsize).^2.*ALVarMu; 
    %Best value of variable "ALVarBeta" will be interpoalted by calculating "Err1" and "Err2" and applying the L-curve mthod  
    Err1 = zeros(length(ALVarBetaList),1);  %Error #1: |u-u^|
    Err2 = zeros(length(ALVarBetaList),1);  %Error #2: |F-grad(u^)|
    disp(['***** Start step',num2str(ALADMMIterStep),' Subproblem2 *****'])
    
    %%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
    % ====== Use "finite difference" or "finite element" methods to solve Subpb2 ======
    if strcmp(DVCpara.Subpb2FDOrFEM,'finiteDifference')==1 %Using the finite difference method
        % ====== Build a sparse finite difference operator ======
        MNL = 1 + (DVCmesh.coordinatesFEM(end,:)-DVCmesh.coordinatesFEM(1,:))./DVCpara.winstepsize;
        tic; Rad=[1,1,1]; FDOperator3 = funDerivativeOp3(MNL(1),MNL(2),MNL(3),DVCpara.winstepsize); toc
        disp('Finish the assembling finite difference operator [D]');
        
        % ===== Use finite difference method ======
        tic; FResidual = FSubpb1-udual; UResidual = USubpb1-vdual; FResidual=FResidual(:); UResidual=UResidual(:);
        Rad=[1,1,1]; [notNeumannBCInd_F,notNeumannBCInd_U] = funFDNotNeumannBCInd3(size(DVCmesh.coordinatesFEM,1),MNL,Rad); 
        %Find indices of nodal points that are not boundary points
        hbar = waitbar(0,'Please wait for Subproblem 2 global step!'); 
        for tempk = 1:length(ALVarBetaList)
            ALVarBeta = ALVarBetaList(tempk); %Assign a value to "ALVarBeta"
            tempAMatrixSub2 = (ALVarBeta*(FDOperator3')*FDOperator3) + ALVarMu*speye(DVCpara.DIM*(MNL(1))*(MNL(2))*(MNL(3)));
            USubpb2temp = (tempAMatrixSub2) \ (ALVarBeta*FDOperator3'*FResidual + ALVarMu*UResidual) ;
            USubpb2 = USubpb1; USubpb2(notNeumannBCInd_U) = USubpb2temp(notNeumannBCInd_U);
            FSubpb2 = FSubpb1; temp = FDOperator3*USubpb2temp; FSubpb2(notNeumannBCInd_F) = temp(notNeumannBCInd_F);
             
            Err1(tempk) = norm(USubpb1(:)-USubpb2(:),2); %Error #1: |u-u^|
            Err2(tempk) = norm(FSubpb1(:)-FSubpb2(:),2); %Error #2: |F-grad(u^)|
            waitbar(tempk/(length(ALVarBetaList)+1));
        end
        ErrSum = Err1+Err2*mean(DVCpara.winstepsize)^2; [~,indexOfbeta] = min(ErrSum); %Apply the L-curve method
        try
            [fitobj] = fit(log10(ALVarBetaList(indexOfbeta-1:1:indexOfbeta+1))',ErrSum(indexOfbeta-1:1:indexOfbeta+1),'poly2');
            p = coeffvalues(fitobj); ALVarBeta = 10^(-p(2)/2/p(1)); %Interpolate the best value of variable "ALVarBeta"
        catch
            ALVarBeta = ALVarBetaList(indexOfbeta);
        end
        % Using optimal beta to solve again
        tempAMatrixSub2 = (ALVarBeta*(FDOperator3')*FDOperator3) + ALVarMu*speye(DVCpara.DIM*(MNL(1))*(MNL(2))*(MNL(3)));
        USubpb2temp = (tempAMatrixSub2) \ (ALVarBeta*FDOperator3'*FResidual + ALVarMu*UResidual) ;
        USubpb2 = USubpb1; USubpb2(notNeumannBCInd_U) = USubpb2temp(notNeumannBCInd_U);
        waitbar(1); close(hbar);
        %%%%%%%%%%%%%% End of using finite difference approximation %%%%%%%%%%%%%%
        
    %%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%    
    elseif strcmp(DVCpara.Subpb2FDOrFEM,'finiteElement')==1  %Using the finite element method
        MNL = size(DVCmesh.xyz0); GaussPtOrder=2; alpha = 0; %Ignore alpha please.
        hbar = waitbar(0,'Please wait for Subproblem 2 global step!'); 
        % ====== Solver using finite element method ======
        for tempk = 1:length(ALVarBetaList)
            ALVarBeta = ALVarBetaList(tempk);
            [USubpb2] = Subpb23(DVCmesh,ALVarBeta,ALVarMu,USubpb1,FSubpb1,udual,vdual,alpha,GaussPtOrder);
            [FSubpb2,~,~] = funGlobal_NodalStrainAvg3(DVCmesh.coordinatesFEM,DVCmesh.elementsFEM,USubpb2,GaussPtOrder);
            Err1(tempk) = norm(USubpb1-USubpb2,2);  %Error #1: |u-u^|
            Err2(tempk) = norm(FSubpb1-FSubpb2,2);  %Error #2: |F-grad(u^)|
            waitbar(tempk/(length(ALVarBetaList)+1));
        end
        Err1Norm = (Err1-mean(Err1))/std(Err1); figure, plot(Err1Norm);
        Err2Norm = (Err2-mean(Err2))/std(Err2); figure, plot(Err2Norm);
        ErrSum = Err1Norm+Err2Norm; figure,plot(ErrSum); [~,indexOfbeta] = min(ErrSum); %Apply the L-curve method
        try
            [fitobj] = fit(log10(ALVarBetaList(indexOfbeta-1:1:indexOfbeta+1))',ErrSum(indexOfbeta-1:1:indexOfbeta+1),'poly2');
            p = coeffvalues(fitobj); ALVarBeta = 10^(-p(2)/2/p(1)); %Interpolate the best value of variable "ALVarBeta"
        catch
            ALVarBeta = ALVarBetaList(indexOfbeta);
        end
        % Using optimal beta to solve again
        [USubpb2] = Subpb23(DVCmesh,ALVarBeta,ALVarMu,USubpb1,FSubpb1,udual,vdual,alpha,GaussPtOrder);
        USubpb2 = full(USubpb2); waitbar(1); close(hbar);

    else %Other unknown methods
        disp('Unknown method to solve Subproblem 2: Wrong input for DVCpara.Subpb2FDOrFEM!');
    end
	ALSubpb2TimeCost(ALADMMIterStep) = toc; toc
    
	%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
    % ------- Before computing strain, we smooth the displacement field a little bit -------
    % USubpb2 = funSmoothDisp3(USubpb2,coordinatesFEM,elementsFEM,x0,y0,winstepsize,DispFilterSize,DispFilterStd);
    % ------- Compute strain field -------- 
    if strcmp(DVCpara.Subpb2FDOrFEM,'finiteDifference')==1 %Using the finite different method
        FSubpb2 = FSubpb1; temp = FDOperator3*USubpb2temp; FSubpb2(notNeumannBCInd_F) = temp(notNeumannBCInd_F);
    elseif strcmp(DVCpara.Subpb2FDOrFEM,'finiteElement')==1 %Using the finite element method
        [FSubpb2,~,~] = funGlobal_NodalStrainAvg3(DVCmesh.coordinatesFEM,DVCmesh.elementsFEM,USubpb2,GaussPtOrder);
    else %Other unknown methods
        disp('Unknown method to solve Subproblem 2: Wrong input for DVCpara.Subpb2FDOrFEM!');
    end

    % ------- Smooth strain field --------
    %for tempi = 1:3, FSubpb2 = funSmoothStrain3(FSubpb2,DVCmesh,DVCpara); end
     
    % ------- Save data ------
    save(['Subpb2_step',num2str(ALADMMIterStep)],'USubpb2','FSubpb2');

    % ------ Plot ------
    Plotdisp_show3(USubpb2,DVCmesh.coordinatesFEM,DVCmesh.elementsFEM);
    Plotstrain_show3(FSubpb2,DVCmesh.coordinatesFEM,DVCmesh.elementsFEM);
    % Or try these codes for a tight view:
    % Plotdisp03(USubpb2,DVCmesh.coordinatesFEM,DVCmesh.elementsFEM,'All');
    % Plotstrain03(full(FSubpb2),xyz0.x,xyz0.y,xyz0.z,size(Img{1}),'All');
    
    % ======= Update dual variables =======
    if strcmp(DVCpara.Subpb2FDOrFEM,'finiteDifference') == 1 %Using the finite different method
        udualtemp1 = (FSubpb2 - FSubpb1); udualtemp2 = udualtemp1(notNeumannBCInd_F);
        vdualtemp1 = (USubpb2 - USubpb1); vdualtemp2 = vdualtemp1(notNeumannBCInd_U);
        udual = zeros(DVCpara.DIM^2*prod(MNL),1); vdual = zeros(DVCpara.DIM*prod(MNL),1);
        udual(notNeumannBCInd_F) = udualtemp2; vdual(notNeumannBCInd_U) = vdualtemp2;
    elseif strcmp(DVCpara.Subpb2FDOrFEM,'finiteElement')==1 %Using the finite element method
        udual = FSubpb2 - FSubpb1; vdual = USubpb2 - USubpb1;
        for tempi=0:8, udual(9*DVCmesh.dirichlet-tempi) = 0; end
        for tempi=0:2, vdual(3*DVCmesh.dirichlet-tempi) = 0; end
    else %Other unknown methods
        disp('Unknown method to solve Subproblem 2: Wrong input for DVCpara.Subpb2FDOrFEM!');
    end

    save(['uvdual_step',num2str(ALADMMIterStep)],'udual','vdual');
    fprintf('------------ Section 5 Done ------------ \n \n')


    %% %%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
    %% Section 6
    fprintf('------------ Section 6 Start ------------ \n')
    % %%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
    % This section is to run ADMM iterations: to solve Subproblems 1 & 2
    % %%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
    
    % ==================== ADMM AL Loop ==========================
    ALADMMIterStep = 1;  %Start to count ADMM iteration step #
    % ADMM stopping criterion: |dispU update| < DVCpara.ADMMtol (unit: voxel)

    HPar=cell(size(HtempPar,2),1); for tempj=1:size(HtempPar,2), HPar{tempj} = HtempPar(:,tempj); end
    while (ALADMMIterStep < 4) %In practice, we can stop ADMM after 4 iteration steps

        ALADMMIterStep = ALADMMIterStep + 1;  %Update ADMM iteratino step #
        
        %%%%%%%%%%%%%%%%%%%%%%% Subproblem 1 %%%%%%%%%%%%%%%%%%%%%%%%%
        disp(['***** Start step',num2str(ALADMMIterStep),' Subproblem1 *****']);
        tic;[USubpb1,~,ALSubpb1TimeCosttemp,convIterPerEletemp] = Subpb13(USubpb2,FSubpb2,udual,vdual,DVCmesh.coordinatesFEM,...
                Df,Img{1},Img{2},ALVarMu,ALVarBeta,HPar,ALADMMIterStep,DVCpara,'GaussNewton',DVCpara.ICGNtol); toc
        FSubpb1 = FSubpb2; ALSubpb1TimeCost(ALADMMIterStep) = ALSubpb1TimeCosttemp; %To store computation time
        convIterPerEle(:,ALADMMIterStep) = convIterPerEletemp; %To store ICGN iteration steps
        %%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
        % % ------  Manually find some bad points from Local Subset ICGN step ------
        % % Comment START
        % disp('--- Start to manually remove bad local points ---')
        % close all; Plotdisp_show3(USubpb1,DVCmesh.coordinatesFEM,DVCmesh.elementsFEM); % Plotuvw(USubpb1,[],xyz0,[]);
        % [row,~] = find(ConvItPerEle(:,ALSolveStep)>DVCpara.Subpb1ICGNMaxIterNum);
        % USubpb1(3*row-2) = nan; USubpb1(3*row-1) = nan; USubpb1(3*row) = nan;
        % MNL = size(DVCmesh.xyz0.x); uvw.u = reshape(USubpb1(1:3:end),MNL); 
        % uvw.v = reshape(USubpb1(2:3:end),MNL); uvw.w = reshape(USubpb1(3:3:end),MNL);
        % 
        % [uvw,cc,RemoveOutliersList] = RemoveOutliers3(uvw,[],DVCpara.qDICOrNot,DVCpara.medianFilterThreshold);
        % USubpb1 = [uvw.u(:),uvw.v(:),uvw.w(:)]'; USubpb1 = USubpb1(:); FSubpb1 = FSubpb1(:);
        % for tempi = 0:8
        %     FSubpb1(9*RemoveOutliersList-tempi) = nan;
        %     FSubpb1(9-tempi:9:end) = reshape((inpaint_nans3(reshape(FSubpb1(9-tempi:9:end),MNL),1)),size(DVCmesh.coordinatesFEM,1),1);
        % end
        % disp('--- Remove bad points: Done. ---')
        % % Comment END
        %%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
        save(['Subpb1_step',num2str(ALADMMIterStep)],'USubpb1','FSubpb1');
         
        %%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
        % ============== Subproblem 2 ==============
        disp(['***** Start step',num2str(ALADMMIterStep),' Subproblem2 *****'])
        if strcmp(DVCpara.Subpb2FDOrFEM,'finiteDifference')==1 %Using finite different method
            tic; FResidual = FSubpb1-udual; UResidual = USubpb1-vdual;
            USubpb2temp = (tempAMatrixSub2) \ (ALVarBeta*FDOperator3'*FResidual + ALVarMu*UResidual) ;
            USubpb2 = USubpb1; USubpb2(notNeumannBCInd_U) = USubpb2temp(notNeumannBCInd_U);
        elseif strcmp(DVCpara.Subpb2FDOrFEM,'finiteElement')==1  %Using the finite element method
            tic; [USubpb2] = Subpb23(DVCmesh,ALVarBeta,ALVarMu,USubpb1,FSubpb1,udual,vdual,alpha,GaussPtOrder); % [] means I don't apply dirichlet & neumann BC here.
            USubpb2 = full(USubpb2);
        else %Other unknown methods
            disp('Unknown method to solve Subproblem 2: Wrong input for DVCpara.Subpb2FDOrFEM!');
        end
        ALSubpb2TimeCost(ALADMMIterStep) = toc; toc
        
        %%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
        % for tempi = 0:2, USubpb2(3*dirichlet-tempi) = USubpb1(3*dirichlet-tempi); end
        % ------- Before computing strain, we smooth the displacement field -------
        % USubpb2 = funSmoothDisp3(USubpb2,DVCmesh,DVCpara);
        % ------- Compute strain field --------
        if strcmp(DVCpara.Subpb2FDOrFEM,'finiteDifference')==1 %Using the finite different method
            FSubpb2 = FSubpb1; temp = FDOperator3*USubpb2temp; FSubpb2(notNeumannBCInd_F) = temp(notNeumannBCInd_F); 
        elseif strcmp(DVCpara.Subpb2FDOrFEM,'finiteElement')==1 %Using the finite element method
            GaussPtOrder=2; [FSubpb2,~,~] = funGlobal_NodalStrainAvg3(DVCmesh.coordinatesFEM,DVCmesh.elementsFEM,USubpb2,GaussPtOrder);
        else %Other unknown methods
            disp('Unknown method to solve Subproblem 2: Wrong input for DVCpara.Subpb2FDOrFEM!');
        end
        
        %%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
        % ------- Smooth strain field --------
        % for tempi = 1:3, FSubpb2 = funSmoothStrain3(FSubpb2,DVCmesh,DVCpara); end
        save(['Subpb2_step',num2str(ALADMMIterStep)],'USubpb2','FSubpb2');
        
        %%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
        % Compute norm of UpdateY
        USubpb2_Old = load(['Subpb2_step',num2str(ALADMMIterStep-1)],'USubpb2');
        USubpb2_New = load(['Subpb2_step',num2str(ALADMMIterStep)],'USubpb2');
        USubpb1_Old = load(['Subpb1_step',num2str(ALADMMIterStep-1)],'USubpb1');
        USubpb1_New = load(['Subpb1_step',num2str(ALADMMIterStep)],'USubpb1');

        % Check ADMM convergence
        if (ImgSeqNum>2) 
            Update_dispU_Subpb2 = norm((USubpb2_Old.USubpb2 - USubpb2_New.USubpb2), 2)/sqrt(size(USubpb2_Old.USubpb2,1));
            try
                Update_dispU_Subpb1 = norm((USubpb1_Old.USubpb1 - USubpb1_New.USubpb1), 2)/sqrt(size(USubpb1_Old.USubpb1,1));
            catch
            end
        end
        try
            disp(['Updated U from the local step  = ',num2str(Update_dispU_Subpb1)]);
            disp(['Updated U from the global step = ',num2str(Update_dispU_Subpb2)]);
        catch
        end
        fprintf('*********************************** \n \n');
        
        %%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
        % Update dual variables------------------------------
        if strcmp(DVCpara.Subpb2FDOrFEM,'finiteDifference')==1 %Using the finite different method
            udualtemp1 =  (FSubpb2(:) - FSubpb1(:)); udualtemp2 = udualtemp1(notNeumannBCInd_F);
            vdualtemp1 =  (USubpb2(:) - USubpb1(:)); vdualtemp2 = vdualtemp1(notNeumannBCInd_U);
            udual(notNeumannBCInd_F) = udual(notNeumannBCInd_F)+udualtemp2;
            vdual(notNeumannBCInd_U) = vdual(notNeumannBCInd_U)+vdualtemp2;
        elseif strcmp(DVCpara.Subpb2FDOrFEM,'finiteElement')==1 %Using the finite element method
            udual = FSubpb2(:) - FSubpb1(:); vdual = USubpb2(:) - USubpb1(:);
            for tempi=0:8, udual(9*DVCmesh.dirichlet-tempi) = 0; end
            for tempi=0:2, vdual(3*DVCmesh.dirichlet-tempi) = 0; end
        else %Other unknown methods
            disp('Unknown method to solve Subproblem 2: Wrong input for DVCpara.Subpb2FDOrFEM!');
        end
        
        save(['uvdual_step',num2str(ALADMMIterStep)],'udual','vdual');
        
        %%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
        try if (Update_dispU_Subpb2 < DVCpara.ADMMtol) || (Update_dispU_Subpb1 < DVCpara.ADMMtol)
                break; 
        end; catch; end 

    end
    fprintf('------------ Section 6 Done ------------ \n \n')

    %%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
    % Plot and save data
    % ------ Plot ------
    close all; Plotdisp_show3(USubpb2,DVCmesh.coordinatesFEM,DVCmesh.elementsFEM);
    Plotstrain_show3(FSubpb1,DVCmesh.coordinatesFEM,DVCmesh.elementsFEM);

    % ------ Try these codes for a tight view ------
    % Plotdisp03(USubpb2,DVCmesh.coordinatesFEM,DVCmesh.elementsFEM,'individual');
    % Plotstrain03(full(FSubpb2),xyz0.x,xyz0.y,xyz0.z,size(Img{1}),'individual');
    
    ResultDisp{ImgSeqNum-1}.U = full(USubpb2);                %Store ALDVC displacement results
    ResultDisp{ImgSeqNum-1}.ULocalICGN = full(ULocalICGN);    %Store Local Subset DVC results
    ResultDisp{ImgSeqNum-1}.U0 = full(U0);                    %Store FFT-based cross correlation DVC results
    
    ResultDefGrad{ImgSeqNum-1}.F = full(FSubpb2);             %Store ALDVC displacement gradient results
    ResultDefGrad{ImgSeqNum-1}.FLocalICGN = full(FLocalICGN); %Store Local Subset DVC (direct) results
    
    ResultMuBeta{ImgSeqNum-1}.beta = ALVarBeta;               %Store ADMM parameter "beta"
    ResultMuBeta{ImgSeqNum-1}.mu = ALVarMu;                   %Store ADMM parameter "mu"
    ResultConvItPerEle{ImgSeqNum-1}.ConvItPerEle = convIterPerEle; %Store ADMM Subpb1 ICGN iteration steps
  
    
end
 

%% Section 7
% %%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
% This section is to check ADMM iterations are converged
% %%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
fprintf('------------ Section 7 Start ------------ \n')
% ====== Check convergence ======
ALSolveStep1 = min(6,ALADMMIterStep);
disp('====== |u^-u| ======');
for ALADMMIterStep = 1:ALSolveStep1
    USubpb2 = load(['Subpb2_step',num2str(ALADMMIterStep )],'USubpb2'); USubpb2=USubpb2.USubpb2(:);
    USubpb1 = load(['Subpb1_step',num2str(ALADMMIterStep )],'USubpb1'); USubpb1=USubpb1.USubpb1(:);
    Update_dispU_Subpb2 = norm((USubpb2-USubpb1), 2)/sqrt(length(USubpb2));
    disp(num2str(Update_dispU_Subpb2));
end
disp('====== |grad(u^)-F| ======');
for ALADMMIterStep = 1:ALSolveStep1
    FSubpb1 = load(['Subpb1_step',num2str(ALADMMIterStep )],'FSubpb1'); FSubpb1=FSubpb1.FSubpb1(:);
    FSubpb2 = load(['Subpb2_step',num2str(ALADMMIterStep )],'FSubpb2'); FSubpb2=FSubpb2.FSubpb2(:);
    UpdateF = norm((FSubpb1-FSubpb2), 2)/sqrt(length(FSubpb1));
    disp(num2str(UpdateF));
end
disp('====== |delta u^| ======');
for ALADMMIterStep = 2:ALSolveStep1
    USubpb2_Old = load(['Subpb2_step',num2str(ALADMMIterStep-1)],'USubpb2'); USubpb2_Old=USubpb2_Old.USubpb2(:);
    USubpb2_New = load(['Subpb2_step',num2str(ALADMMIterStep)],'USubpb2'); USubpb2_New=USubpb2_New.USubpb2(:);
    Update_dispU_Subpb2 = norm((USubpb2_Old-USubpb2_New), 2)/sqrt(length(USubpb2_New));
    disp(num2str(Update_dispU_Subpb2));
end
disp('====== |delta dual var udual| ======');
for ALADMMIterStep = 2:ALSolveStep1
    uvdual_Old = load(['uvdual_step',num2str(ALADMMIterStep-1)],'udual'); uvdual_Old=uvdual_Old.udual(:);
    uvdual_New = load(['uvdual_step',num2str(ALADMMIterStep)],'udual'); uvdual_New=uvdual_New.udual(:);
    UpdateW = norm((uvdual_Old-uvdual_New), 2)/sqrt(length(uvdual_New));
    disp(num2str(UpdateW));
end
disp('====== |delta dual var vdual| ======');
for ALADMMIterStep = 2:ALSolveStep1
    uvdual_Old = load(['uvdual_step',num2str(ALADMMIterStep-1)],'vdual'); uvdual_Old=uvdual_Old.vdual(:);
    uvdual_New = load(['uvdual_step',num2str(ALADMMIterStep)],'vdual'); uvdual_New=uvdual_New.vdual(:);
    Updatev = norm((uvdual_Old-uvdual_New), 2)/sqrt(length(uvdual_New));
    disp(num2str(Updatev));
end
fprintf('------------ Section 7 Done ------------ \n \n')

% ------ Uncomment these codes to delete temp files ------
% for tempi = 1:ALSolveStep
%     file_name_Subpb1 = ['Subpb1_step',num2str(tempi),'.mat'];
%     file_name_Subpb2 = ['Subpb2_step',num2str(tempi),'.mat'];
%     file_name_dual = ['uvdual_step',num2str(tempi),'.mat'];
%     delete(file_name_Subpb1); delete(file_name_Subpb2); delete(file_name_dual);
% end
% 
% % ------ clear temp variables ------
% clear a ALSub1BadPtNum ALSub1Timetemp atemp b btemp cc ConvItPerEletemp hbar Hbar


%% Section 6' 
% %%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
% This section is only for "incremental" tracking mode where "cumulative"
% displacement fields can be interpolated w.r.t the first reference frame
% %%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
if strcmp(DVCpara.trackingMode,'incremental')==1

    % ------ To store the moved coordinates of nodal points in frame 2's DVC-FE-mesh ------
    tempx = ResultFEMeshEachFrame{1}.coordinatesFEM(:,1);
    tempy = ResultFEMeshEachFrame{1}.coordinatesFEM(:,2);
    tempz = ResultFEMeshEachFrame{1}.coordinatesFEM(:,3);
    coord = [tempx,tempy,tempz]; coordCurr = coord;

    hbar = waitbar(0,'Calculate cumulative disp from incremental displacements'); %Initialize a waitbar

    for ImgSeqNum = 2 : length(fileNameAll)

        waitbar((ImgSeqNum-1)/(length(fileNameAll)-1)); %Update waitbar

        tempxyz0 = ResultFEMeshEachFrame{ImgSeqNum-1}.xyz0;
        MNL = size(tempxyz0.x);

        tempx = reshape( ResultFEMeshEachFrame{ImgSeqNum-1}.coordinatesFEM(:,1), MNL );
        tempy = reshape( ResultFEMeshEachFrame{ImgSeqNum-1}.coordinatesFEM(:,2), MNL );
        tempz = reshape( ResultFEMeshEachFrame{ImgSeqNum-1}.coordinatesFEM(:,3), MNL );

        tempu = reshape( ResultDisp{ImgSeqNum-1}.U(1:3:end), MNL );
        tempv = reshape( ResultDisp{ImgSeqNum-1}.U(2:3:end), MNL );
        tempw = reshape( ResultDisp{ImgSeqNum-1}.U(3:3:end), MNL );

        disp_x = interp3(tempy,tempx,tempz,tempu,coordCurr(:,2),coordCurr(:,1),coordCurr(:,3),'makima'); %'makima' interpolation
        disp_y = interp3(tempy,tempx,tempz,tempv,coordCurr(:,2),coordCurr(:,1),coordCurr(:,3),'makima'); %'makima' interpolation
        disp_z = interp3(tempy,tempx,tempz,tempw,coordCurr(:,2),coordCurr(:,1),coordCurr(:,3),'makima'); %'makima' interpolation

        disp_x = inpaint_nans3(reshape(disp_x,MNL),0);  %Fill NANs
        disp_y = inpaint_nans3(reshape(disp_y,MNL),0);  %Fill NANs
        disp_z = inpaint_nans3(reshape(disp_z,MNL),0);  %Fill NANs

        coordCurr = coordCurr + [disp_x(:), disp_y(:), disp_z(:)]; %Calculate points current coordinates
        U_accum = (coordCurr - coord)'; %Calculate cumulative displacements
        U_accum = U_accum(:); %Reshape to a one-column vector: U = [..., dispU_x_pti, dispU_y_pti, ...]

        %%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
        % ------ Smooth displacements ------
        % Plotdisp_show3(full(ULocal),coordinatesFEM,elementsFEM);
        % prompt = 'Do you want to smooth displacement? (0-yes; 1-no)';
        % DoYouWantToSmoothOnceMore = input(prompt); DispFilterSize=0; DispFilterStd=1;
        DoYouWantToSmoothOnceMore = 0;
        SmoothTime = 0;
        try
            while DoYouWantToSmoothOnceMore==0 && SmoothTime<3
                U_accum = funSmoothDisp3(U_accum,DVCmesh,DVCpara);
                % close all; Plotdisp_show3(full(ULocal),coordinatesFEM,elementsFEM); % Plotuv(ULocal,x0,y0);
                SmoothTime = SmoothTime + 1; % DoYouWantToSmoothOnceMore = input(prompt);
            end
        catch
        end

        ResultDisp{ImgSeqNum-1}.U_accum = U_accum; %Store calculated cumulative displacement fields

    end

    close(hbar); %Close the waitbar
 
close all;
for ImgSeqNum = 2 %Feel free to change image frame #
    Plotdisp03(ResultDisp{ImgSeqNum-1}.U_accum, ...
        ResultFEMeshEachFrame{ImgSeqNum-1}.coordinatesFEM, ...
        ResultFEMeshEachFrame{ImgSeqNum-1}.elementsFEM, 0);
end

end



%% Section 8
fprintf('------------ Section 8 Start ------------ \n')
% %%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
% This section is to compute strain and plot figures
% %%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
% ------ Smooth displacements ------
DVCpara.DoYouWantToSmoothOnceMore = funParaInput('SmoothDispOrNot');
% ------ Choose strain computation method ------
DVCpara.MethodToComputeStrain = funParaInput('StrainMethodOp'); 
% ------ Choose strain type (infinitesimal, Eulerian, Green-Lagrangian) ------
DVCpara.StrainType = funParaInput('StrainType');
% ------ Plot displacement & strain components individually or all together ------
DVCpara.PlotComponentEachOrAll = funParaInput('PlotComponentEachOrAll');
 
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
% ------ Start plotting part -----
for ImgSeqNum = 2:length(ImgNormalized)
    
    disp(['Current image frame #: ', num2str(ImgSeqNum),'/',num2str(length(ImgNormalized))]);
    
    %%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
    fNormalizedNewIndex = ImgSeqNum-mod(ImgSeqNum-2,DVCpara.ImgSeqIncUnit)-1;
    if DVCpara.ImgSeqIncUnit > 1
        FEMeshIndLast = floor(fNormalizedNewIndex/DVCpara.ImgSeqIncUnit);
    elseif DVCpara.ImgSeqIncUnit == 1
        FEMeshIndLast = floor(fNormalizedNewIndex/DVCpara.ImgSeqIncUnit)-1;
    end
    FEMeshInd = FEMeshIndLast + 1;
    
    if FEMeshInd == 1
        USubpb2 = ResultDisp{ImgSeqNum-1}.U; %+ ResultDisp{10}.U + ResultDisp{20}.U;
        coordinatesFEM = ResultFEMesh{1}.coordinatesFEM; 
        elementsFEM = ResultFEMesh{1}.elementsFEM;
        if (ImgSeqNum-1 == 1) || (DVCpara.ImgSeqIncROIUpdateOrNot==1), UFEMesh = 0*USubpb2; end
    else
        USubpb2 = ResultDisp{ImgSeqNum-1}.U;
        if mod(ImgSeqNum-2,DVCpara.ImgSeqIncUnit) == 0
            coordinatesFEM = ResultFEMesh{FEMeshInd}.coordinatesFEM;
            elementsFEM = ResultFEMesh{FEMeshInd}.elementsFEM;
            coordinatesFEMLast = ResultFEMesh{FEMeshIndLast}.coordinatesFEM;
            UFEMeshLast = ResultDisp{ImgSeqNum-2}.U + UFEMesh;
            xq = coordinatesFEM(:,1); yq = coordinatesFEM(:,2);
            UFEMesh = 0*USubpb2;
            UFEMesh(1:2:end) = griddata(coordinatesFEMLast(:,1),coordinatesFEMLast(:,2),UFEMeshLast(1:2:end),xq,yq,'v4');
            UFEMesh(2:2:end) = griddata(coordinatesFEMLast(:,1),coordinatesFEMLast(:,2),UFEMeshLast(2:2:end),xq,yq,'v4');
        end
        USubpb2 = USubpb2 + UFEMesh;
    end
    %%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
    %USubpb2 = ResultDisp{ImgSeqNum-1}.U;
    FSubpb2 = ResultDefGrad{ImgSeqNum-1}.F;
    %%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
    
    xList = min(coordinatesFEM(:,1)):DVCpara.winstepsize(1):max(coordinatesFEM(:,1)); M = length(xList);
    yList = min(coordinatesFEM(:,2)):DVCpara.winstepsize(2):max(coordinatesFEM(:,2)); N = length(yList);
    zList = min(coordinatesFEM(:,3)):DVCpara.winstepsize(3):max(coordinatesFEM(:,3)); L = length(zList);
    [xGrid,yGrid,zGrid] = ndgrid(xList,yList,zList);
    xGrid = xGrid-reshape(UFEMesh(1:3:end),size(xGrid));
    yGrid = yGrid-reshape(UFEMesh(2:3:end),size(yGrid));
    zGrid = zGrid-reshape(UFEMesh(3:3:end),size(zGrid));
    xyz0.x = xGrid; xyz0.y = yGrid; xyz0.z = zGrid;
 
    if size(USubpb2,1)==1
        ULocal = full(USubpb2_New.USubpb2); FLocal = full(FSubpb2.FSubpb2); 
    else
        ULocal = full(USubpb2); FLocal = full(FSubpb2);
    end

    %%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
    % ------ Smooth displacements ------
    %Plotdisp_show3(full(ULocal),coordinatesFEM,elementsFEM);
    % prompt = 'Do you want to smooth displacement? (0-yes; 1-no)';
    % DoYouWantToSmoothOnceMore = input(prompt); DispFilterSize=0; DispFilterStd=1;
    SmoothTime=0;
    try
        while DoYouWantToSmoothOnceMore==0 && SmoothTime<3
            ULocal = funSmoothDisp3(ULocal,DVCmesh,DVCpara);
            % close all; Plotdisp_show3(full(ULocal),coordinatesFEM,elementsFEM); % Plotuv(ULocal,x0,y0); 
            SmoothTime = SmoothTime + 1; %DoYouWantToSmoothOnceMore = input(prompt);
        end
    catch
    end
    
    %%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
    % ----- Compute strain field ------
    ComputeStrain3;
    
    %%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
    % ----- Plot results -----
    close all;
    
    % ------ Plot disp ------
    Plotdisp03(ULocal,DVCmesh.coordinatesFEM,DVCmesh.elementsFEM,DVCpara.PlotComponentEachOrAll);
     
    % ------ Plot strain ------
    %Plotstrain_show3(FLocal,coordinatesFEM,elementsFEM);
    Plotstrain03(full(FStraintemp),xyz0.x(1+Rad(1):M-Rad(1),1+Rad(2):N-Rad(2),1+Rad(3):L-Rad(3)), ...
        xyz0.y(1+Rad(1):M-Rad(1),1+Rad(2):N-Rad(2),1+Rad(3):L-Rad(3)), ...
        xyz0.z(1+Rad(1):M-Rad(1),1+Rad(2):N-Rad(2),1+Rad(3):L-Rad(3)),size(Img{1}),DVCpara.PlotComponentEachOrAll);
    
    % ------ Store strain data ------
    ResultStrain{ImgSeqNum-1}.Strain = FStraintemp;
    tempx = xyz0.x(1+Rad(1):M-Rad(1),1+Rad(2):N-Rad(2),1+Rad(3):L-Rad(3));
    tempy = xyz0.y(1+Rad(1):M-Rad(1),1+Rad(2):N-Rad(2),1+Rad(3):L-Rad(3));
    tempz = xyz0.z(1+Rad(1):M-Rad(1),1+Rad(2):N-Rad(2),1+Rad(3):L-Rad(3));
    ResultStrain{ImgSeqNum-1}.coordinatesFEMStrain = [tempx(:), tempy(:), tempz(:)]; 
    
    % % ------- Add filter and plot strain field -------
    % Plotstrain_Fij;
    % %caxis auto; load('colormap_RdYlBu.mat'); colormap(cMap)
    % Plotstrain03(FStraintemp,xyz0.x(1+Rad:M-Rad,1+Rad:N-Rad,1+Rad:L-Rad),xyz0.y(1+Rad:M-Rad,1+Rad:N-Rad,1+Rad:L-Rad), ...
    %    xyz0.z(1+Rad:M-Rad,1+Rad:N-Rad,1+Rad:L-Rad),size(Img{1}),DVCpara.PlotComponentEachOrAll);
    
    %%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
    % ------ Save figures ------
    % Write down your own codes to save figures! E.g.: % print(['fig_dispu'],'-dpdf');
    if strcmp(DVCpara.PlotComponentEachOrAll,'All')==1
        figure(1); saveas(gcf,['fig_ImgSeqNum_',num2str(ImgSeqNum),'_disp.fig']);
        figure(2); saveas(gcf,['fig_ImgSeqNum_',num2str(ImgSeqNum),'_strain.fig']);
    elseif strcmp(DVCpara.PlotComponentEachOrAll,'Individual')==1
        figure(1); saveas(gcf,['fig_ImgSeqNum_',num2str(ImgSeqNum),'_dispx.fig']);
        figure(2); saveas(gcf,['fig_ImgSeqNum_',num2str(ImgSeqNum),'_dispy.fig']);
        figure(3); saveas(gcf,['fig_ImgSeqNum_',num2str(ImgSeqNum),'_dispz.fig']);
        figure(4); saveas(gcf,['fig_ImgSeqNum_',num2str(ImgSeqNum),'_strainexx.fig']);
        figure(5); saveas(gcf,['fig_ImgSeqNum_',num2str(ImgSeqNum),'_straineyy.fig']);
        figure(6); saveas(gcf,['fig_ImgSeqNum_',num2str(ImgSeqNum),'_strainezz.fig']);
        figure(7); saveas(gcf,['fig_ImgSeqNum_',num2str(ImgSeqNum),'_strainexy.fig']);
        figure(8); saveas(gcf,['fig_ImgSeqNum_',num2str(ImgSeqNum),'_strainexz.fig']);
        figure(9); saveas(gcf,['fig_ImgSeqNum_',num2str(ImgSeqNum),'_straineyz.fig']);
    else
        disp('=== Wrong input in DVCpara.PlotComponentEachOrAll! ===')
    end
    %%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
    
end
fprintf('------------ Section 8 Done ------------ \n \n')


%% Save data again including the computed strain 
results_name = ['results_ws',num2str(DVCpara.winsize(1)),'_st',num2str(DVCpara.winstepsize(1)),'.mat'];
save(results_name, 'file_name','DVCpara','DVCmesh','ResultDisp','ResultDefGrad','ResultStrain','ResultFEMesh',...
    'ALSubpb1TimeCost','ALSubpb2TimeCost','ALADMMIterStep','ResultMuBeta','ResultConvItPerEle', ...
    'ResultCoordinatesFEM','ResultElementsFEM','ResultSizeOfFFTSearch');

  
%% %%%%%%%%%%%%% Extensions for body and slice plottings %%%%%%%%%%%%%%%%
disp('Extensions for body and slice plottings'); pause;  
plotExt_bodyslice; % Feel free to modify this file (./PlotFiles/plotExt_bodyslice.m) on your purpose.







