import json
import sys
import matplotlib.pyplot as plt

def main():
    # check if the usage was correct, has to provide a json file as command line argument
    if len(sys.argv) < 2:
        print("Not enough args, Usage: display_json_time.py file_name.json")
        sys.exit(1)
    
    # extract the json file name
    file_name = sys.argv[1]


    try:
        #open the file and load it as json
        with open(file_name, 'r') as file:
            #get json data
            data = json.load(file)

            
            avg_boot_time = [] #declare avg boot time array
            avg_solution_time = [] #declare avg solution time array
            avg_shutdown_time = [] #declare avg shutdown time array

            #loop through each run
            for i in range(len(data["runs"])):
                #fill in values (averages)
                avg_boot_time.append(data["runs"][i]["timing_summary"]["boot_time_s"]["avg"])
                avg_solution_time.append(data["runs"][i]["timing_summary"]["solution_time_s"]["avg"])
                avg_shutdown_time.append(data["runs"][i]["timing_summary"]["shutdown_time_s"]["avg"])
            
            #get array of # of firecracker instances (as string so it doesn't fill all mumerical positions)
            instance_count = [str(x) for x in data[("vm_counts")]] 

            #average boot time plot:
            plt.bar(instance_count, avg_boot_time)
            plt.xlabel('# of instances')
            plt.ylabel('avg boot time')
            plt.title('Boot Time vs. # Instances')
            plt.show()

            #average solution time plot:
            plt.bar(instance_count, avg_solution_time)
            plt.xlabel('# of instances')
            plt.ylabel('avg solution time')
            plt.title('Solution Time vs. Instances')
            plt.show()


            #average shutdown time plot:
            plt.bar(instance_count, avg_shutdown_time)
            plt.xlabel('# of instances')
            plt.ylabel('avg shutdown time')
            plt.title('Shutdown Time vs. Instances')
            plt.show()


                
    #file not found error
    except FileNotFoundError:
        print(f"File {file_name} not found")
    #json decoder error
    except json.JSONDecodeError:
        print(f"Error: could not decode json file")
    #general error, display it
    except Exception as e:
        print(f"An error has occured: {e}")


if __name__ == "__main__":
    main()