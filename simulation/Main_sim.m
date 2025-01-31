%% clear the possible remnant on previous running

set(0,'defaulttextinterpreter','none');
dbclear all;
clearvars -except init traj index Data_sim;
close all;
clc;

%% Simulation Settings and Bike Parameters
% General Parameters

    % Gravitational Acceleration
        g = 9.81;
    % Name of the model
        model = 'Main_bikesim';
    % Simulation time
        sim_time = 400;

    % Sampling Time
        Ts = 0.01; 
    % First closest point selection in reference 
    % Starts at 2 because the one before closest is in the local reference as well
        ref_start_idx = 2;
    % Horizon distance [m]
        hor_dis = 10;
    % Constant Speed [m/s]
        v = 2.4;    

% Open the Simulink Model
    open([model '.slx']);
% Choose the solver
    set_param(model,'AlgebraicLoopSolver','TrustRegion');
% Choose The Bike - Options: 'red', 'black', 'green' and 'scooter'
    bike = 'red';
% Load the parameters of the specified bicycle
    bike_params = LoadBikeParameters(bike); 
% bike model
    bike_model = 1; % 1 = non-linear model || 2 = linear model
% 0 = Don't run test cases & save measurementdata in CSV || 1 = run test cases || 2 = generate ref yourself
    Run_tests = 0; 
% Take estimated states from a specific time if wanted (0 == initial conditions are set to zero || 1 == take from an online test)
    if exist('init','var') ~= 1
        init = 0;
    end
    time_start = 14.001;         % what time do you want to take

%% Initial states

if init == 1

%     data_lab = readtable('Logging_data\Test_session_14_06\data_8.csv');
% data_lab = readtable('Logging_data\Test_session_27_06\data_15.csv');
    data_lab = Data_sim;
    % Delete the data before reseting the trajectory and obtain X/Y position
    reset_traj = find(data_lab.ResetTraj==1,1,'last');
    data_lab(1:reset_traj,:) = [];
    longitude0 = deg2rad(11);
    latitude0 = deg2rad(57);
    Earth_rad = 6371000.0;
    
    X = Earth_rad * (data_lab.LongGPS_deg_ - longitude0) * cos(latitude0);
    Y = Earth_rad * (data_lab.LatGPS_deg_ - latitude0);

    % Obtain the relative time of the data
%     Y = round(X,N) 
    data_lab.Time = round((data_lab.Time_ms_- data_lab.Time_ms_(1))*0.001, 4);
    if exist('index','var') ~= 1
        index = find(data_lab.Time == time_start);
    end

    initial_state.roll = data_lab.StateEstimateRoll_rad_(index);
    initial_state.roll_rate = data_lab.StateEstimateRollrate_rad_s_(index);
    initial_state.steering = data_lab.StateEstimateDelta_rad_(index);
    initial_state_estimate.x = data_lab.StateEstimateX_m_(index) - X(1);
    initial_state_estimate.y = data_lab.StateEstimateY_m_(index) - Y(1);
    initial_state_estimate.heading = data_lab.StateEstimatePsi_rad_(index);

elseif init == 0
        initial_state.roll = deg2rad(0);
        initial_state.roll_rate = deg2rad(0);
        initial_state.steering = deg2rad(0);
        initial_state.x = 0;
        initial_state.y = 5;
        initial_state.heading = deg2rad(60);
        initial_pose = [initial_state.x; initial_state.y; initial_state.heading];
        initial_state_estimate = initial_state;
else
    disp('Bad initialization');
end

%% Reference trajectory generation

% SHAPE options: sharp_turn, line, infinite, circle, ascent_sin, smooth_curve
type = 'infinite';
% Distance between points
ref_dis = 0.1;
% Number# of reference points
N = 100;
% Scale (only for infinite and circle)
scale = 40;
% Angle [deg] (only for sharp turn)
angle = 60;

[Xref,Yref,Psiref] = ReferenceGenerator(type,ref_dis,N,scale,angle);

% Use a generated trajectory
% traj = readtable('Traj_ref_test\name_of_trajectorymat.csv');
if exist('traj','var') == 1
    traj = table2array(traj);
    traj = [traj(:,1)-traj(1,1), traj(:,2)-traj(1,2), traj(:,3)];
    Xref = traj(3:end,1);
    Yref = traj(3:end,2);
    Psiref = traj(3:end,3);
end

test_curve=[Xref,Yref,Psiref];
Nn = size(test_curve,1); % needed for simulink

%% Reference test (warnings and initialization update)
if ((Run_tests == 2) && init == 0)

Output_reference_test = referenceTest(test_curve,hor_dis,Ts,initial_pose,v, ref_dis);

% update initial states if offset is detected
initial_state.x = Output_reference_test(1);
initial_state.y = Output_reference_test(2);
initial_state.heading = Output_reference_test(3);
initial_state.heading = Psiref(3);
initial_pose = [initial_state.x; initial_state.y; initial_state.heading];
initial_state_estimate = initial_state;
end

%% Unpacked bike_params
h = bike_params.h_mod;
lr = bike_params.lr_mod;
lf = bike_params.lf_mod; 
lambda = bike_params.lambda_mod;
c = bike_params.c_mod;
m = bike_params.m_mod;
h_imu = bike_params.IMU_height_mod;

% Correction IMU
IMU_x = bike_params.IMU_x_mod;
IMU_roll = bike_params.IMU_roll_mod;
IMU_pitch = bike_params.IMU_pitch_mod;            
IMU_yaw = bike_params.IMU_yaw_mod;

% Convert orientation offsets to radians
roll = IMU_roll * pi / 180;
pitch = IMU_pitch * pi / 180;
yaw = IMU_yaw * pi / 180;

% Calculate transformation matrix
Rx = [1 0 0; 0 cos(roll) -sin(roll); 0 sin(roll) cos(roll)];   % Rotation matrix for roll
Ry = [cos(pitch) 0 sin(pitch); 0 1 0; -sin(pitch) 0 cos(pitch)]; % Rotation matrix for pitch
Rz = [cos(yaw) -sin(yaw) 0; sin(yaw) cos(yaw) 0; 0 0 1];        % Rotation matrix for yaw

T = Rz*Ry*Rx;                                                      

%% Disturbance Model
% 
% % Roll Reference  
% roll_ref_generation;%long time ago left by other students, it's helpless now but keep it
% 
% % Steering Rate State Perturbation
% pert_deltadot_state = 0; % Switch ON (1) / OFF (0) the perturbation
% pert_deltadot_state_fun = @(time)  -0.5*(time>10) && (ceil(mod(time/3,2)) == 1) &&(time<30);
% 
% % Roll Rate State Perturbation
% pert_phidot_state = 0; % Switch ON (1) / OFF (0) the perturbation
% pert_phidot_state_fun = @(time) cos(time)*(time>10 && time < 10.4);

%% Bike State-Space Model

% Continuous-Time Model

% % Controllable Canonical Form
%     A = [0 g/bike_params.h ; 1 0];
%     B = [1 ; 0];
%     C = [bike_params.a*v/(bike_params.b*bike_params.h) g*bike_params.inertia_front/(bike_params.h^3*bike_params.m)+v^2/(bike_params.b*bike_params.h)];
%     D = [bike_params.inertia_front/(bike_params.h^2*bike_params.m)];

% % Observable Canonical Form
%     A = [0 g/bike_params.h ; 1 0];
%     B = [g*bike_params.inertia_front/(bike_params.h^3*bike_params.m)+(v^2./(bike_params.b*bike_params.h)-bike_params.a*bike_params.c*g/(bike_params.b*bike_params.h^2)).*sin(bike_params.lambda) ;
%         bike_params.a*v/(bike_params.b*bike_params.h).*sin(bike_params.lambda)];
%     C = [0 1];
%     D = [bike_params.inertia_front/(bike_params.h^2*bike_params.m)];
% 
% % Linearized System
%     linearized_sys = ss(A,B,C,D);
% % Augmented System
%     fullstate_sys = ss(linearized_sys.A,linearized_sys.B,eye(size(linearized_sys.A)),0);
% % Discretized System
%     discretized_sys = c2d(linearized_sys,Ts);

%% Balancing Controller

% Outer loop -- Roll Tracking
P_balancing_outer = 1.3;
I_balancing_outer = 0.0;
D_balancing_outer = 0.0;


% Inner loop -- Balancing
P_balancing_inner = 3;
I_balancing_inner = 0;
D_balancing_inner = 0;  

%% The LQR controller

% error model for LQR controller calculation
A_con=[0 v;0 0];
B_con=[lr*v/(lr+lf);v/(lr+lf)];

%  kk=0.000000010;
%  kk=2.581e-7;
%  kk=9e-7;
 kk=6e-7;
%  Q=kk*[100 0;0 1000];
 Q=kk*[1000 0;0 100];
 R=0.2;
%  R=0.5;
 [K,S,e] = lqr(A_con,B_con,Q,R);
 k1=K(1);
 k2=K(2);

e2_max=deg2rad(30);%Here is the e2_max we used to calculate e1_max
e1_max=abs(-k2*e2_max/k1);% k1,k2 has been known, so we can calculate e1_max

% e2_max=deg2rad(30);
% e1_max=abs(1000);

%% MPC Trajectory controller
max_permissible_e1=100;
max_permissible_e2=100;
a = lr;
b = lr+lf;

N_outer=130; %prediction horizont
%penalty matrices 
Q_outer=[1 0; 0 1]*1e-2;  % penalty on state deviation
Pf_outer=[3 0; 0 100];  % penalty on final prediction step, i.e. "how important to reach"
R_outer=1;          % penalty on control signal 

% Q_outer=eye(2)*1e-2;  % penalty on state deviation
% Pf_outer=eye(2)*1e8;  % penalty on final prediction step, i.e. "how important to reach"
% R_outer=2;            % penalty on control signal 

% x=[e1 e2]'
A_outer=[0 v;0 0];
B_outer=[a*v/b;v/b];

C_outer=eye(2);
D_outer=zeros(1,2)';

sys_outer = ss(A_outer,B_outer,C_outer,D_outer);

% Discretization
sys_dis_outer = c2d(sys_outer,Ts);
Ad_outer = sys_dis_outer.A;
Bd_outer = sys_dis_outer.B;
Cd_outer = sys_dis_outer.C;
Dd_outer = sys_dis_outer.D;

%mpc 
stateOfConstraint_outer=[1 0;
                   -1 0;
                   0 1;
                   0 -1];
stateConstraintVal_outer=[max_permissible_e1;
                    max_permissible_e1;
                    max_permissible_e2;
                    max_permissible_e2];
inputConstraint_outer=[1;
                -1];

inputConstraintVal_outer=deg2rad(20);%max_permissible_str-deg2rad(10); % harder constraint on outer?

[rowInputConstraint_outer,colInputConstraint_outer]=size(inputConstraint_outer);
[rowStateOfConstraint_outer,colStateOfConstraint_outer]=size(stateOfConstraint_outer);

%Obs. constraints have the form Fx +Gu <=h, different from MPC course...
%Size of F:
%   - Cols: cols in x constr. times prediction steps (N) 
%   - Rows: rows in x constr. times N + rows in u constr.
%           times N
F_outer=[kron([eye(N_outer)],stateOfConstraint_outer);
    zeros(rowInputConstraint_outer*N_outer,colStateOfConstraint_outer*N_outer)];
%Size of G:
%   - Cols: cols in u constr. times N
%   - Rows: rows in x constr. times N + rows in u constr.
%           times N
G_outer=[zeros(N_outer*rowStateOfConstraint_outer,N_outer);kron(eye(N_outer),[1; -1])];

%Size of h_mpc:
%   -Cols: 1
%   -Rows: rows in x constr. times N + rows in u constr.
%           times N
h_mpc_outer=[kron([ones(1*N_outer,1)],stateConstraintVal_outer);
    ones(N_outer*rowInputConstraint_outer,1)*inputConstraintVal_outer];

mpc_outer_params=struct();
mpc_outer_params.Ad=Ad_outer;
mpc_outer_params.Bd=Bd_outer;
mpc_outer_params.Cd=Cd_outer;
mpc_outer_params.Dd=Dd_outer;
mpc_outer_params.N=N_outer;
mpc_outer_params.Q=Q_outer;
mpc_outer_params.Pf=Pf_outer;
mpc_outer_params.R=R_outer;
mpc_outer_params.F=F_outer;
mpc_outer_params.G=G_outer;
mpc_outer_params.h=h_mpc_outer;


%% Transfer function for heading in wrap traj
%feed forward trasfer function for d_psiref to steering reference (steering contribution for heading changes)
num = 1;
den = [lr/(lr+lf), v/(lr+lf)];
[A_t, B_t, C_t, D_t] = tf2ss(num,den);

% Discretize the ss
Ad_t = (eye(size(A_t))+Ts*A_t);
Bd_t = B_t*Ts;

%% Kalman Filter

% % A matrix (linear bicycle model with constant velocity)
% % Est_States := [X Y psi phi phi_dot delta v]
A = [0 0 0 0 0 0 1;
     0 0 v 0 0 v*(lr/(lf+lr))*sin(lambda) 0;
     0 0 0 0 0 (v/(lr+lf))*sin(lambda) 0;
     0 0 0 0 1 0 0;
     0 0 0 (g/h) 0 ((v^2/h)-(g*lr*c/(h^2*(lr+lf))))*sin(lambda) 0;
     0 0 0 0 0 0 0;
     0 0 0 0 0 0 0];

% B matrix (linear bicycle model with constant velocity)
B = [0 0 0 0 ((v*lr)/(h*(lr+lf))) 1 0]';

% Including GPS
C1 = [1 0 0 0 0 0 0;
     0 1 0 0 0 0 0;
     0 0 0 -g+((-h_imu*g)/h) 0 (-h_imu*(h*v^2-(g*lr*c)))*sin(lambda)/((lr+lf)*h^2) + (v^2)*sin(lambda)/(lr+lf) 0;
     0 0 0 0 1 0 0;
     0 0 0 0 0 (v)*sin(lambda)/(lr+lf) 0;
     0 0 0 0 0 1 0;
     0 0 0 0 0 0 1];

D1 = [0 0 (-h_imu*lr*v)/((lr+lf)*h) 0 0 0 0]';

% Excluding GPS
C2 = [(-g+((-h_imu*g)/h)) 0 (-h_imu*(h*v^2-(g*lr*c)))*sin(lambda)/((lr+lf)*h^2)+(v^2)*sin(lambda)/(lr+lf) 0;
      0 1 0 0;
      0 0 (v)*sin(lambda)/(lr+lf) 0;
      0 0 1 0;
      0 0 0 1];

D2 = [(-h_imu*lr*v)/((lr+lf)*h) 0 0 0 0]';

% Discretize the model
A_d = (eye(size(A))+Ts*A);
B_d = Ts*B;

% Load the Q and R matrices
load('Q_and_R_backup_red_bike.mat');

% Compute Kalman Gain
    % including GPS
    [P1,Kalman_gain1,eig] = idare(A_d',C1',Q,R,[],[]);
    eig1 = abs(eig);
    Kalman_gain1 = Kalman_gain1';
    Ts_GPS = 0.1; % sampling rate of the GPS
    counter = (Ts_GPS / Ts) - 1 ; % Upper limit of the counter for activating the flag

% Polish the kalman gain (values <10-5 are set to zero)
for i = 1:size(Kalman_gain1,1)
    for j = 1:size(Kalman_gain1,2)
        if abs(Kalman_gain1(i,j)) < 10^-5
            Kalman_gain1(i,j) = 0;
        end
    end
end 

% Kalman_gain excluding GPS
Kalman_gain2 = Kalman_gain1(4:7,3:7);

%% Save matrix in XML/CSV

matrixmat = [A_d; B_d'; C1; D1';Kalman_gain1];

filename_matrix = 'matrixmat.csv'; % Specify the filename
csvwrite(filename_matrix, matrixmat); % Write the matrix to the CSV file

filename_trajectory = 'trajectorymat.csv'; % Specify the filename
csvwrite(filename_trajectory, test_curve); % Write the matrix to the CSV file

 %% Start the Simulation
if Run_tests == 0 || Run_tests == 2

tic
try Results = sim(model);
    catch error_details %note: the model has runned for one time here
end
toc

% Simulation Messages and Warnings
% if Results.stop.Data(end) == 1
%     disp('Message: End of the trajectory has been reached');
% end

% save the states for offline kalman
bikedata_simulation_bikestates = array2table([Results.bike_states.Time Results.bike_states.Data]);
filename_simulation_bikestates = 'bikedata_simulation_real_states.csv'; % Specify the filename
bikedata_simulation_bikestates.Properties.VariableNames(1:8) = {'Time', 'X', 'Y', 'Psi', 'Roll', 'Rollrate', 'Delta', 'Velocity'};
writetable(bikedata_simulation_bikestates ,filename_simulation_bikestates);

% save measurement data and estimations for offline kalman
bikedata_simulation = array2table([Results.estimated_states.Time Results.estimated_states.Data Results.delta_e1.Data Results.delta_e2.Data ...
Results.delta_psi.Data Results.delta_ref.Data Results.roll_ref.Data Results.e1.Data Results.e2.Data]);
filename_simulation= 'bikedata_simulation.csv'; % Specify the filename
bikedata_simulation.Properties.VariableNames(1:15) = {'Time', 'X_estimated', 'Y_estimated', 'Psi_estimated', 'Roll_estimated', 'Rollrate_estimated', 'Delta_estimated', 'Velocity_estimated','delta_e1','delta_e2','delta_psi','delta_ref','ref_roll','error1','error2'};
writetable(bikedata_simulation,filename_simulation);

%% Plotting
%name of the plot
Tnumber = 'No test case: General simulation run';
        Plot_bikesimulation_results(Tnumber, Ts, test_curve, Results);
end

%% Test cases for validation

if Run_tests == 1

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%TEST CASE 1 Sparse infinite
disp('Test case 1: Infinite')

type = 'infinite';
ref_dis = 0.1;
N = 100; 
scale = 100; 
[Xref,Yref,Psiref] = ReferenceGenerator(type,ref_dis,N,scale);
test_curve1=[Xref,Yref,Psiref];
Nn = size(test_curve1,1); % needed for simulink

%test reference
Output_reference_test = referenceTest(test_curve1,hor_dis,Ts,initial_pose,v,ref_dis);
initial_state.x = Output_reference_test(1);
initial_state.y = Output_reference_test(2);
initial_state.heading = Output_reference_test(3);
initial_pose = [initial_state.x; initial_state.y; initial_state.heading];
initial_state_estimate = initial_state;

try Results1 = sim(model);
    catch error_details 
end
% Simulation Messages and Warnings
if Results1.stop.Data(end) == 1
    disp('Message: End of the trajectory has been reached');
end

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%TEST CASE 2 Large offset X:-5 Y:0 PSI: 0
disp('Test case 2: Large offset');

type = 'line';
ref_dis = 0.1;
N = 1000; 
scale = 100;
[Xref,Yref,Psiref] = ReferenceGenerator(type,ref_dis,N,scale);
test_curve2=[Xref,Yref,Psiref];
Nn = size(test_curve2,1); % needed for simulink

%test reference
Output_reference_test = referenceTest(test_curve2,hor_dis,Ts,initial_pose,v,ref_dis);
initial_state.x = Output_reference_test(1);
initial_state.y = Output_reference_test(2)-5;
initial_state.heading = Output_reference_test(3)-pi/4;
initial_pose = [initial_state.x; initial_state.y; initial_state.heading];
initial_state_estimate = initial_state;

try Results2 = sim(model);
    catch error_details 
end
% Simulation Messages and Warnings
if Results2.stop.Data(end) == 1
    disp('Message: End of the trajectory has been reached');
end

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%% 
%TEST CASE 3 Small circle
disp('Test case 3: Small circle')

type = 'circle';
ref_dis = 0.5;
N = 100; 
scale = 5; 
[Xref,Yref,Psiref] = ReferenceGenerator(type,ref_dis,N,scale);
test_curve3=[Xref,Yref,Psiref];
Nn = size(test_curve3,1); % needed for simulink

%test reference
Output_reference_test = referenceTest(test_curve3,hor_dis,Ts,initial_pose,v,ref_dis);
initial_state.x = Output_reference_test(1);
initial_state.y = Output_reference_test(2);
initial_state.heading = Output_reference_test(3);
initial_pose = [initial_state.x; initial_state.y; initial_state.heading];
initial_state_estimate = initial_state;

try Results3 = sim(model);
    catch error_details 
end
% Simulation Messages and Warnings
if Results3.stop.Data(end) == 1
    disp('Message: End of the trajectory has been reached');
end

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%% 
%TEST CASE 4 Large disturbance
disp('Test case 4: Large disturbance')

type = 'line';
ref_dis = 0.01;
N = 2100; 
scale = 10; 
[Xref,Yref,Psiref] = ReferenceGenerator(type,ref_dis,N,scale);
Yref(1050) = 300;

test_curve4=[Xref,Yref,Psiref];
Nn = size(test_curve4,1); % needed for simulink

%test reference
Output_reference_test = referenceTest(test_curve4,hor_dis,Ts,initial_pose,v,ref_dis);
initial_state.x = Output_reference_test(1);
initial_state.y = Output_reference_test(2);
initial_state.heading = Output_reference_test(3);
initial_pose = [initial_state.x; initial_state.y; initial_state.heading];
initial_state_estimate = initial_state;

try Results4 = sim(model);
    catch error_details 
end

% Simulation Messages and Warnings
if Results4.stop.Data(end) == 1
    disp('Message: End of the trajectory has been reached');
end

end

%% Plotting Testcases
if Run_tests == 1
    close all
    %Test case 1
    Tnumber = 'Test case 1: Infinite';

        Plot_bikesimulation_results(Tnumber, Ts, test_curve1, Results1);
    %Test case 2 
    Tnumber = 'Test case 2: Large offset';
 
        Plot_bikesimulation_results(Tnumber, Ts, test_curve2, Results2);
    %Test case 3    
    Tnumber = 'Test case 3: Small circle';
     
        Plot_bikesimulation_results(Tnumber, Ts, test_curve3, Results3);
    %Test case 4 
    Tnumber = 'Test case 4: Sharp turn';

        Plot_bikesimulation_results(Tnumber, Ts, test_curve4, Results4);

end
